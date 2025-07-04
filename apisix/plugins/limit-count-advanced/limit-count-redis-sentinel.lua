local delayed_syncer = require("apisix.plugins.limit-count-advanced.delayed-syncer")
local sliding_window = require("apisix.plugins.limit-count-advanced.sliding-window.sliding-window")
local sliding_window_store = require("apisix.plugins.limit-count-advanced."
                                     .. "sliding-window.store.redis")
local limit_count_local = require("apisix.plugins.limit-count-advanced.limit-count-local")
local redis_cli_sentinel = require("apisix.plugins.limit-count-advanced.util").redis_cli_sentinel
local core = require("apisix.core")
local assert = assert
local setmetatable = setmetatable
local tostring = tostring
local _M = {}

local mt = {
    __index = _M
}

local script = core.string.compress_script([=[
    local ttl = redis.call('pttl', KEYS[1])
    if ttl < 0 then
        redis.call('set', KEYS[1], ARGV[1] - ARGV[3], 'EX', ARGV[2])
        return {ARGV[1] - ARGV[3], ARGV[2] * 1000}
    end
    return {redis.call('incrby', KEYS[1], 0 - ARGV[3]), ttl}
]=])


function _M.new(plugin_name, limit, window, conf)
    assert(limit > 0 and window > 0)
    local fallback_limiter, err = limit_count_local.new(plugin_name,
                                                    limit, window, conf.window_type)
    if not fallback_limiter then
        return nil, err
    end

    if conf.window_type == "sliding" then
        local sw_limit_count, err = sliding_window.new_with_red_cli_factory(sliding_window_store,
                                                         limit, window, redis_cli_sentinel, conf)
        if not sw_limit_count then
            return nil, err
        end
        sw_limit_count.fallback_limiter = fallback_limiter
        local self = {
            window_type = conf.window_type,
            limit_count = sw_limit_count,
        }

        self.delayed_syncer = delayed_syncer.new(limit, window, conf, self.limit_count)
        return setmetatable(self, mt)
    end

    local self = {
        limit = limit,
        window = window,
        conf = conf,
        plugin_name = plugin_name,
        fallback_limiter = fallback_limiter,
    }
    self.delayed_syncer = delayed_syncer.new(limit, window, conf, self)
    return setmetatable(self, mt)
end


function _M.incoming_delayed(self, key, cost, syncer_id)
    core.log.info("delayed sync to redis-sentinel") -- for sanity test
    local remaining, reset, err = self.delayed_syncer:delayed_sync(key, cost, syncer_id)
    if not remaining then
        return nil, err, 0
    end
    if remaining < 0 then
        return nil, "rejected", reset
    end
    return 0, remaining, reset
end


function _M.incoming(self, key, cost)
    if self.window_type == "sliding" then
        return self.limit_count:incoming(key, cost)
    end

    local conf = self.conf
    local red, err = redis_cli_sentinel(conf)
    if not red then
        return nil, err, 0
    end

    local ttl = 0
    key = self.plugin_name .. tostring(key)
    local res, err = red:eval(script, 1, key, self.limit, self.window, cost or 1)
    if err then
        return nil, err, ttl
    end

    local remaining = res[1]
    ttl = res[2] / 1000.0

    if remaining < 0 then
        return nil, "rejected", ttl
    end
    return 0, remaining, ttl
end

return _M
