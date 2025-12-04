local core = require("apisix.core")
local redis_new = require("resty.redis").new
local redis_sentinel = require("resty.redis.connector")
local _M = {}

local tostring = tostring

local commit_script = core.string.compress_script([=[
    assert(tonumber(ARGV[3]) >= 0, "cost must be at least 0")
    local ttl = redis.call('ttl', KEYS[1])
    if ttl < 0 then
        redis.call('set', KEYS[1], ARGV[3], 'EX', ARGV[2])
        return {ARGV[3], ARGV[2] * 1000}
    end
    return {redis.call('incrby', KEYS[1], ARGV[3]), ttl}
]=])


function _M.redis_cli(conf)
    local red = redis_new()
    local timeout = conf.redis_timeout or 1000    -- 1sec

    red:set_timeouts(timeout, timeout, timeout)

    local sock_opts = {
        ssl = conf.redis_ssl,
        ssl_verify = conf.redis_ssl_verify
    }

    local ok, err = red:connect(conf.redis_host, conf.redis_port or 6379, sock_opts)
    if not ok then
        return nil, err
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
                return nil, "failed to change redis db, err: " .. err
            end
        end
    elseif err then
        -- core.log.info(" err: ", err)
        return nil, err
    end
    return red, nil
end

function _M.redis_cli_sentinel(conf)
    local redis_conf = {
        password = conf.redis_password,
        sentinel_username = conf.sentinel_username,
        sentinel_password = conf.sentinel_password,
        db = conf.redis_database or 0,
        sentinels = conf.redis_sentinels or {},
        master_name = conf.redis_master_name,
        role = conf.redis_role or "master",
        connect_timeout = conf.redis_connect_timeout or 1000,
        read_timeout = conf.redis_read_timeout or 1000,
        keepalive_timeout = conf.redis_keepalive_timeout or 60000,
    }

    local sentinel_client, err = redis_sentinel.new(redis_conf)
    if not sentinel_client then
        return nil, "failed to create redis client: " .. (err or "unknown error")
    end

    -- In case of errors, returns "nil, err, previous_errors" where err is
    -- the last error received, and previous_errors is a table of the previous errors.
    local red, err, previous_errors = sentinel_client:connect()
    if not red then
        local err = "redis connection failed, err: " .. (err or "unknown error")
        if previous_errors and #previous_errors > 0 then
            err = err .. ", previous_errors: " .. core.table.concat(previous_errors, ", ")
        end
        return nil, err
    end
    return red, nil
end


function _M.redis_incoming(self, key, commit, cost)
    if self.window_type == "sliding" then
        return self.limit_count:incoming(key, cost)
    end

    local red = self.red_cli
    if not red then
        return nil, "redis client not initialized", 0
    end

    local limit = self.limit
    local window = self.window
    key = self.plugin_name .. tostring(key)

    local res, err = red:eval(commit_script, 1, key, limit, window, commit and cost or 0)
    if err then
        return nil, err, 0
    end

    local remaining = limit - res[1] - (commit and 0 or cost)
    local ttl = res[2] / 1000.0

    if remaining < 0 then
        return nil, "rejected", ttl
    end

    return 0, remaining, ttl
end


return _M
