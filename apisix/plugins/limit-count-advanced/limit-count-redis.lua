--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
local core = require("apisix.core")
local delayed_syncer = require("apisix.plugins.limit-count-advanced.delayed-syncer")
local sliding_window = require("apisix.plugins.limit-count-advanced.sliding-window.sliding-window")
local sliding_window_store = require("apisix.plugins.limit-count-advanced."
                                     .. "sliding-window.store.redis")
local limit_count_local = require("apisix.plugins.limit-count-advanced.limit-count-local")
local redis_cli = require("apisix.plugins.limit-count-advanced.util").redis_cli

local assert = assert
local setmetatable = setmetatable
local tostring = tostring


local _M = {version = 0.3}


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
        local sw_limit_count, err = sliding_window.new(sliding_window_store, limit, window, conf)
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
    core.log.info("delayed sync to redis") -- for sanity test
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
    local red, err = redis_cli(conf)
    if not red then
        return red, err, 0
    end

    local limit = self.limit
    local window = self.window
    local res
    key = self.plugin_name .. tostring(key)

    local ttl = 0
    res, err = red:eval(script, 1, key, limit, window, cost or 1)

    if err then
        return nil, err, ttl
    end

    local remaining = res[1]
    ttl = res[2] / 1000.0

    local ok, err = red:set_keepalive(10000, 100)
    if not ok then
        return nil, err, ttl
    end

    if remaining < 0 then
        return nil, "rejected", ttl
    end
    return 0, remaining, ttl
end


return _M
