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
local util = require("apisix.plugins.limit-count-advanced.util")
local redis_cli = require("apisix.plugins.limit-count-advanced.util").redis_cli

local assert = assert
local setmetatable = setmetatable
local timer_at = ngx.timer.at


local _M = {version = 0.3}


local mt = {
    __index = _M
}


function _M.new(plugin_name, limit, window, conf)
    assert(limit > 0 and window > 0)

    local fallback_limiter, err = limit_count_local.new(plugin_name,
                                                    limit, window, conf.window_type)
    if not fallback_limiter then
        return nil, err
    end

    if conf.window_type == "sliding" then
        local sw_limit_count, err = sliding_window.new_with_red_cli_factory(sliding_window_store,
                                                                   limit, window, redis_cli, conf)
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


function _M.incoming(self, key, cost, commit)
    if self.window_type == "sliding" then
        return self.limit_count:incoming(key, cost)
    end

    local red, err = redis_cli(self.conf)
    if not red then
        return nil, err, 0
    end
    self.red_cli = red
    local delay, remaining, ttl = util.redis_incoming(self, key, commit, cost)
    if not delay and remaining ~= "rejected" then
        return nil, remaining, ttl
    end

    local ok, err = red:set_keepalive(10000, 100)
    if not ok then
        core.log.error("failed to set keepalive for redis: ", err)
    end

    return delay, remaining, ttl
end


function _M.log_phase_incoming(self, key, cost, commit)
    local ok, err = timer_at(0, function ()
        local delay, err = self:incoming(key, cost, commit)
        if not delay then
            if err ~= "rejected" then
                core.log.error("failed to sync limit count in log phase: ", err)
            end
        end
    end)
    if not ok then
        core.log.error("failed to schedule timer: ", err)
    end
end


return _M
