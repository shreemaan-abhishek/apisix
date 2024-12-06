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
local apisix_plugin = require("apisix.plugin")
local tab_insert = table.insert
local ipairs = ipairs
local pairs = pairs

local NO_DELAYED_SYNC = -1

local limit_redis_cluster_new
local limit_redis_new
local limit_local_new
do
    local local_src = "apisix.plugins.limit-count-advanced.limit-count-local"
    limit_local_new = require(local_src).new

    local redis_src = "apisix.plugins.limit-count-advanced.limit-count-redis"
    limit_redis_new = require(redis_src).new

    local cluster_src = "apisix.plugins.limit-count-advanced.limit-count-redis-cluster"
    limit_redis_cluster_new = require(cluster_src).new
end
local lrucache = core.lrucache.new({
    type = 'plugin', serial_creating = true,
})
local group_conf_lru = core.lrucache.new({
    type = 'plugin',
})
local group_key_lru = core.lrucache.new({
    type = 'plugin',
})

local policy_to_additional_properties = {
    redis = {
        properties = {
            redis_host = {
                type = "string", minLength = 2
            },
            redis_port = {
                type = "integer", minimum = 1, default = 6379,
            },
            redis_username = {
                type = "string", minLength = 1,
            },
            redis_password = {
                type = "string", minLength = 0,
            },
            redis_database = {
                type = "integer", minimum = 0, default = 0,
            },
            redis_timeout = {
                type = "integer", minimum = 1, default = 1000,
            },
            redis_ssl = {
                type = "boolean", default = false,
            },
            redis_ssl_verify = {
                type = "boolean", default = false,
            },
        },
        required = {"redis_host"},
    },
    ["redis-cluster"] = {
        properties = {
            redis_cluster_nodes = {
                type = "array",
                minItems = 1,
                items = {
                    type = "string", minLength = 2, maxLength = 100
                },
            },
            redis_password = {
                type = "string", minLength = 0,
            },
            redis_timeout = {
                type = "integer", minimum = 1, default = 1000,
            },
            redis_cluster_name = {
                type = "string",
            },
            redis_cluster_ssl = {
                type = "boolean", default = false,
            },
            redis_cluster_ssl_verify = {
                type = "boolean", default = false,
            },
        },
        required = {"redis_cluster_nodes", "redis_cluster_name"},
    },
}
local schema = {
    type = "object",
    properties = {
        count = {type = "integer", exclusiveMinimum = 0},
        time_window = {type = "integer",  exclusiveMinimum = 0},
        window_type = {
            type = "string",
            enum = { "fixed", "sliding" },
            default = "fixed",
        },
        group = {type = "string"},
        key = {type = "string", default = "remote_addr"},
        key_type = {type = "string",
            enum = {"var", "var_combination", "constant"},
            default = "var",
        },
        rejected_code = {
            type = "integer", minimum = 200, maximum = 599, default = 503
        },
        rejected_msg = {
            type = "string", minLength = 1
        },
        policy = {
            type = "string",
            enum = {"local", "redis", "redis-cluster"},
            default = "local",
        },
        allow_degradation = {type = "boolean", default = false},
        show_limit_quota_header = {type = "boolean", default = true},
        sync_interval = {
            type = "number", default = NO_DELAYED_SYNC,
        },
    },
    required = {"count", "time_window"},
    ["if"] = {
        properties = {
            policy = {
                enum = {"redis"},
            },
        },
    },
    ["then"] = policy_to_additional_properties.redis,
    ["else"] = {
        ["if"] = {
            properties = {
                policy = {
                    enum = {"redis-cluster"},
                },
            },
        },
        ["then"] = policy_to_additional_properties["redis-cluster"],
    }
}
local metadata_defaults = {
    limit_header = "X-RateLimit-Limit",
    remaining_header = "X-RateLimit-Remaining",
    reset_header = "X-RateLimit-Reset",
}
local metadata_schema = {
    type = "object",
    properties = {
        limit_header = {
            type = "string",
            default = metadata_defaults.limit_header,
        },
        remaining_header = {
            type = "string",
            default = metadata_defaults.remaining_header,
        },
        reset_header = {
            type = "string",
            default = metadata_defaults.reset_header,
        },
    },
}

local schema_copy = core.table.deepcopy(schema)

local _M = {
    schema = schema,
    metadata_schema = metadata_schema,
}


local function table_insert_tail(t, ...)
    for i = 1, select("#", ...) do
        local x = select(i, ...)
        if x then
            core.table.insert(t, x)
        end
    end
end


local function gen_group_key(conf)
    local keys = {
        conf.group,
        conf.count,
        conf.time_window,
        conf.window_type,
    }
    if conf.policy == "redis" then
        table_insert_tail(keys,
            conf.redis_host,
            conf.redis_port,
            conf.redis_username,
            conf.redis_password,
            conf.redis_database
        )
    elseif conf.policy == "redis-cluster" then
        table_insert_tail(keys,
            conf.redis_cluster_name,
            conf.redis_username,
            conf.redis_password
        )
    end
    return table.concat(keys, "_")
end


function _M.check_schema(conf, schema_type)
    if schema_type == core.schema.TYPE_METADATA then
        return core.schema.check(metadata_schema, conf)
    end
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end

    if conf.group then
        -- means that call by some plugin not support
        if conf._vid then
            return false, "group is not supported"
        end

        local fields = {}
        -- When the goup field is configured,
        -- we will use schema_copy to get the whitelist of properties,
        -- so that we can avoid getting injected properties.
        for k in pairs(schema_copy.properties) do
            tab_insert(fields, k)
        end
        local extra = policy_to_additional_properties[conf.policy]
        if extra then
            for k in pairs(extra.properties) do
                tab_insert(fields, k)
            end
        end
    end

    if conf.policy == "redis" or conf.policy == "redis-cluster" then
        if conf.sync_interval ~= NO_DELAYED_SYNC then
            if conf.sync_interval < 0.1 then
                return false, "sync_interval should not be smaller than 0.1"
            end

            if conf.sync_interval > conf.time_window then
                return false, "sync_interval should be smaller than time_window"
            end
        end
    end

    return true
end


local function create_limit_obj(conf, plugin_name)
    core.log.info("create new " .. plugin_name .. " plugin instance")

    if not conf.policy or conf.policy == "local" then
        return limit_local_new("plugin-" .. plugin_name, conf.count,
                               conf.time_window, conf.window_type)
    end

    if conf.policy == "redis" then
        return limit_redis_new("plugin-" .. plugin_name,
                               conf.count, conf.time_window, conf)
    end

    if conf.policy == "redis-cluster" then
        return limit_redis_cluster_new("plugin-" .. plugin_name, conf.count,
                                       conf.time_window, conf)
    end

    return nil
end


local function gen_limit_key(conf, ctx, key)
    if conf.group then
        local group_key = group_key_lru(ctx.route_id, ctx.conf_version, gen_group_key, conf)
        return group_key .. ':' .. key
    end

    -- here we add a separator ':' to mark the boundary of the prefix and the key itself
    -- Here we use plugin-level conf version to prevent the counter from being resetting
    -- because of the change elsewhere.
    -- A route which reuses a previous route's ID will inherits its counter.
    local new_key = ctx.conf_type .. ctx.conf_id .. ':' .. apisix_plugin.conf_version(conf)
                    .. ':' .. key
    if conf._vid then
        -- conf has _vid means it's from workflow plugin, add _vid to the key
        -- so that the counter is unique per action.
        return new_key .. ':' .. conf._vid
    end

    return new_key
end


local function gen_limit_obj(conf, ctx, plugin_name)
    local key
    if conf.group then
        key = group_key_lru(ctx.route_id, ctx.conf_version, gen_group_key, conf)
        return group_conf_lru(key, "", create_limit_obj, conf, plugin_name)
    end
    if conf._vid then
        key = conf.policy .. '#' .. conf._vid
    else
        key = conf.policy
    end

    return core.lrucache.plugin_ctx(lrucache, ctx, key, create_limit_obj, conf, plugin_name)
end

function _M.rate_limit(conf, ctx, name, cost)
    core.log.info("ver: ", ctx.conf_version)

    local lim, err = gen_limit_obj(conf, ctx, name)

    if not lim then
        core.log.error("failed to fetch limit.count object: ", err)
        if conf.allow_degradation then
            return
        end
        return 500
    end
    core.log.debug("limit object: ", core.json.delay_encode(lim, true))

    local conf_key = conf.key
    local key
    if conf.key_type == "var_combination" then
        local err, n_resolved
        key, err, n_resolved = core.utils.resolve_var(conf_key, ctx.var)
        if err then
            core.log.error("could not resolve vars in ", conf_key, " error: ", err)
        end

        if n_resolved == 0 then
            key = nil
        end
    elseif conf.key_type == "constant" then
        key = conf_key
    else
        key = ctx.var[conf_key]
    end

    if key == nil then
        core.log.info("The value of the configured key is empty, use client IP instead")
        -- When the value of key is empty, use client IP instead
        key = ctx.var["remote_addr"]
    end

    key = gen_limit_key(conf, ctx, key)
    core.log.info("limit key: ", key)

    local delay, remaining, reset
    if not conf.policy or conf.policy == "local" then
        delay, remaining, reset = lim:incoming(key, true, conf, cost)
    else
        local enable_delayed_sync = (conf.sync_interval ~= NO_DELAYED_SYNC)
        if enable_delayed_sync then
            local extra_key
            if conf._vid then
                extra_key = conf.policy .. '#' .. conf._vid
            else
                extra_key = conf.policy
            end
            local plugin_instance_id = core.lrucache.plugin_ctx_id(ctx, extra_key)
            delay, remaining, reset = lim:incoming_delayed(key, cost, plugin_instance_id)
        else
            delay, remaining, reset = lim:incoming(key, cost)
        end
    end

    local metadata = apisix_plugin.plugin_metadata("limit-count-advanced")
    if metadata then
        metadata = metadata.value
    else
        metadata = metadata_defaults
    end
    core.log.debug("metadata: ", core.json.delay_encode(metadata))

    if not delay then
        local err = remaining
        if err == "rejected" then
            -- show count limit header when rejected
            if conf.show_limit_quota_header then
                core.response.set_header(metadata.limit_header, conf.count,
                    metadata.remaining_header, 0,
                    metadata.reset_header, reset)
            end

            if conf.rejected_msg then
                return conf.rejected_code, { error_msg = conf.rejected_msg }
            end
            return conf.rejected_code
        end

        core.log.error("failed to limit count: ", err)
        if conf.allow_degradation then
            return
        end
        return 500, {error_msg = "failed to limit count"}
    end

    if conf.show_limit_quota_header then
        core.response.set_header(metadata.limit_header, conf.count,
            metadata.remaining_header, remaining,
            metadata.reset_header, reset)
    end
end


return _M
