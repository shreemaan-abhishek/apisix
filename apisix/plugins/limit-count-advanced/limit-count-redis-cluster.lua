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

local rediscluster = require("resty.rediscluster")
local core = require("apisix.core")
local delayed_syncer = require("apisix.plugins.limit-count-advanced.delayed-syncer")
local sliding_window = require("apisix.plugins.limit-count-advanced.sliding-window.sliding-window")
local sliding_window_store = require("apisix.plugins.limit-count-advanced.sliding-window.store.redis")

local setmetatable = setmetatable
local tostring = tostring
local ipairs = ipairs

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


function _M.new(plugin_name, limit, window, conf)
    local red_cli, err = new_redis_cluster(conf)
    if not red_cli then
        return nil, err
    end

    if conf.window_type == "sliding" then

        local sw_limit_count, err = sliding_window.new(sliding_window_store, limit, window, conf, red_cli)
        if not sw_limit_count then
            return nil, err
        end

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
        red_cli = red_cli,
    }
    self.delayed_syncer = delayed_syncer.new(limit, window, conf, self)
    return setmetatable(self, mt)
end

function _M.incoming_delayed(self, key, cost, syncer_id)
    core.log.info("delayed sync to redis-cluster") -- for sanity test
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

    local red = self.red_cli
    local limit = self.limit
    local window = self.window
    key = self.plugin_name .. tostring(key)

    local ttl = 0
    local res, err = red:eval(script, 1, key, limit, window, cost or 1)

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
