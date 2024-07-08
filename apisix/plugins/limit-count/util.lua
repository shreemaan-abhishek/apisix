local core = require("apisix.core")
local consts = require("apisix.constants")
local redis_new = require("resty.redis").new
local rediscluster = require("resty.rediscluster")

local floor = math.floor

local ngx_timer = ngx.timer
local redis_stop
local redis_cluster_stop
local _M = {}
local syncer_started
local to_be_synced = {}
local redis_confs = {}

local function redis_cli(conf)
  local red = redis_new()
  local timeout = conf.redis_timeout or 1000 -- 1sec

  red:set_timeouts(timeout, timeout, timeout)

  local sock_opts = {
    ssl = conf.redis_ssl,
    ssl_verify = conf.redis_ssl_verify
  }

  local ok, err = red:connect(conf.redis_host, conf.redis_port or 6379, sock_opts)
  if not ok then
    return false, err
  end

  local count
  count, err = red:get_reused_times()
  if 0 == count then
    if conf.redis_password and conf.redis_password ~= '' then
      local ok, err
      if conf.redis_username then
        ok, err = red:auth(conf.redis_username, conf.redis_password)
      else
        ok, err = red:auth(conf.redis_password)
      end
      if not ok then
        return nil, err
      end
    end

    -- select db
    if conf.redis_database ~= 0 then
      local ok, err = red:select(conf.redis_database)
      if not ok then
        return false, "failed to change redis db, err: " .. err
      end
    end
  elseif err then
    -- core.log.info(" err: ", err)
    return nil, err
  end
  return red, nil
end


local function new_redis_cluster(conf)
  local config = {
    -- can set different name for different redis cluster
    name = conf.redis_cluster_name,
    serv_list = {},
    read_timeout = conf.redis_timeout,
    auth = conf.redis_password,
    dict_name = "plugin-limit-count-redis-cluster-slot-lock",
    connect_opts = {
      ssl = conf.redis_cluster_ssl,
      ssl_verify = conf.redis_cluster_ssl_verify,
    }
  }

  for i, conf_item in ipairs(conf.redis_cluster_nodes) do
    local host, port, err = core.utils.parse_addr(conf_item)
    if err then
      return nil, "failed to parse address: " .. conf_item
          .. " err: " .. err
    end

      config.serv_list[i] = {ip = host, port = port}
  end

  local red_cli, err = rediscluster:new(config)
  if not red_cli then
    return nil, "failed to new redis cluster: " .. err
  end

  return red_cli
end


local function sync_counter_data(premature, counter, script)
  if premature then
    return
  end
  for key, _ in pairs(to_be_synced) do
    local num_reqs, err = counter:get(key .. consts.REDIS_COUNTER)
    if not num_reqs then
      core.log.error("failed to get num_reqs shdict during periodic sync: ", err)
      return
    end

    local conf = redis_confs[key]

    local red, err
    if conf.policy == "redis" then
      red, err = redis_cli(conf)
    elseif conf.policy == "redis-cluster" then
      red, err = new_redis_cluster(conf)
    else
      core.log.error("invalid policy type: ", conf.policy)
      return
    end

    if not red then
      core.log.error("failed to get redis client during periodic sync: ", err)
      return
    end

    local res, err = red:eval(script, 1, key, conf.count, conf.time_window, num_reqs)
    if err then
      core.log.error("failed to sync shdict data to redis: ", err)
      return
    end

    local remaining = res[1]
    local ttl = tonumber(res[2])
    if not ttl then
      ttl = 0
    end
    ttl = floor(ttl) -- float to int

    core.log.info("syncing shdict num_req counter to redis. remaining: ", remaining, " ttl: ", ttl, " reqs: ", num_reqs)
    counter:set(key .. consts.SHDICT_REDIS_REMAINING, tonumber(remaining), tonumber(ttl))
    counter:incr(key .. consts.REDIS_COUNTER, 0 - num_reqs)

    if (not redis_stop and (conf.policy == "redis")) or (not redis_cluster_stop and (conf.policy == "redis-cluster")) then
      local ok, err = ngx_timer.at(conf.sync_interval, sync_counter_data, counter, script)
      if not ok then
        core.log.error("failed to create redis syncer timer: ", err, ". New main redis syncer will be created.")
        syncer_started = false -- next incoming request will pick this up and create a new timer
      end
    end
  end
end

function _M.rate_limit_with_delayed_sync(conf, counter, key, cost, limit, window, script)
  local err
  if not syncer_started then
    syncer_started, err = ngx_timer.at(conf.sync_interval, sync_counter_data, counter, script)
  end

  if not syncer_started then
    core.log.error("failed to create main redis syncer timer: ", err, ". Will retry next time.")
  end

  to_be_synced[key] = true -- add to table for syncing
  redis_confs[key] = conf

  local incr, ierr = counter:incr(key .. consts.REDIS_COUNTER, cost, 0)
  if not incr then
    return nil, "failed to incr num req shdict: " .. ierr, 0
  end
  core.log.info("num reqs passed since sync to redis: ", incr)

  local ttl, _ = counter:ttl(key .. consts.SHDICT_REDIS_REMAINING)
  if not ttl then
    ttl = 0
  end
  local remaining, err = counter:incr(key .. consts.SHDICT_REDIS_REMAINING, 0 - cost, limit, window)
  if not remaining then
    return nil, err, ttl
  end

  if remaining < 0 then
    return nil, "rejected", ttl
  end

  return 0, remaining, ttl
end


function _M.redis_syncer_stop()
  redis_stop = true
end


function _M.redis_cluster_syncer_stop()
  redis_cluster_stop = true
end

_M.redis_cli = redis_cli
_M.new_redis_cluster = new_redis_cluster

return _M
