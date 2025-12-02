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
local tab_concat = table.concat
local pairs = pairs
local ipairs = ipairs
local select = select
local tonumber = tonumber
local type = type
local tostring = tostring
local str_format = string.format
local get_phase = ngx.get_phase

local NO_DELAYED_SYNC = -1

local limit_redis_cluster_new
local limit_redis_new
local limit_redis_sentinel_new
local limit_local_new
do
    local local_src = "apisix.plugins.limit-count-advanced.limit-count-local"
    limit_local_new = require(local_src).new

    local redis_src = "apisix.plugins.limit-count-advanced.limit-count-redis"
    limit_redis_new = require(redis_src).new

    local cluster_src = "apisix.plugins.limit-count-advanced.limit-count-redis-cluster"
    limit_redis_cluster_new = require(cluster_src).new

    local sentinel_src = "apisix.plugins.limit-count-advanced.limit-count-redis-sentinel"
    limit_redis_sentinel_new = require(sentinel_src).new
end
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
    ["redis-sentinel"] = {
        properties = {
            redis_sentinels = {
                type     = "array",
                minItems = 1,
                items    = {
                    type       = "object",
                    properties = {
                        host = { type = "string", minLength = 2 },
                        port = { type = "integer", minimum = 1, maximum = 65535 },
                    },
                    required = { "host", "port" },
                    additionalProperties = false,
                },
            },
            redis_master_name       = { type = "string", minLength = 1 },
            redis_role              = {
                                        type = "string",
                                        enum = { "master", "slave" },
                                        default = "master"
                                      },
            redis_connect_timeout   = { type = "integer", minimum = 1, default = 1000 },
            redis_read_timeout      = { type = "integer", minimum = 1, default = 1000 },
            redis_keepalive_timeout = { type = "integer", minimum = 1, default = 60000 },
            redis_database          = { type = "integer", minimum = 0, default = 0 },
            sentinel_username       = { type = "string", minLength = 1 },
            sentinel_password       = { type = "string", minLength = 0 },
        },
        required = { "redis_sentinels", "redis_master_name" },
    },
}
local schema = {
    type = "object",
    properties = {
        count = {
            oneOf = {
                {type = "integer", exclusiveMinimum = 0},
                {type = "string"},
            },
        },
        time_window = {
            oneOf = {
                {type = "integer", exclusiveMinimum = 0},
                {type = "string"},
            },
        },
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
            enum = {"local", "redis", "redis-cluster", "redis-sentinel"},
            default = "local",
        },
        allow_degradation = {type = "boolean", default = false},
        show_limit_quota_header = {type = "boolean", default = true},
        sync_interval = {
            type = "number", default = NO_DELAYED_SYNC,
        },
        rules = {
            type = "array",
            items = {
                type = "object",
                properties = {
                    count = {
                        oneOf = {
                            {type = "integer", exclusiveMinimum = 0},
                            {type = "string"},
                        },
                    },
                    time_window = {
                        oneOf = {
                            {type = "integer", exclusiveMinimum = 0},
                            {type = "string"},
                        },
                    },
                    key = {type = "string"},
                    header_prefix = {
                        type = "string",
                        description = "prefix for rate limit headers"
                    },
                },
                required = {"count", "time_window", "key"},
            },
        },
    },
    oneOf = {
        {
            required = {"count", "time_window"},
        },
        {
            required = {"rules"},
        }
    },
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
        ["else"] = {
            ["if"] = {
                properties = { policy = { enum = { "redis-sentinel" } } },
            },
            ["then"] = policy_to_additional_properties["redis-sentinel"],
        },
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
    return tab_concat(keys, "_")
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

    local keys = {}
    for _, rule in ipairs(conf.rules or {}) do
        if keys[rule.key] then
            return false, str_format("duplicate key '%s' in rules", rule.key)
        end
        keys[rule.key] = true
    end

    return true
end


local function create_limit_obj(conf, rule, plugin_name)
    core.log.info("create new " .. plugin_name .. " plugin instance",
        ", rule: ", core.json.delay_encode(rule, true))

    if not conf.policy or conf.policy == "local" then
        return limit_local_new("plugin-" .. plugin_name, rule.count,
                               rule.time_window, conf.window_type)
    end

    if conf.policy == "redis" then
        return limit_redis_new("plugin-" .. plugin_name,
                               rule.count, rule.time_window, conf)
    end

    if conf.policy == "redis-cluster" then
        return limit_redis_cluster_new("plugin-" .. plugin_name, rule.count,
                                       rule.time_window, conf)
    end

    if conf.policy == "redis-sentinel" then
        return limit_redis_sentinel_new("plugin-" .. plugin_name, rule.count,
                                        rule.time_window, conf)
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


local function resolve_var(ctx, value)
    if type(value) == "string" then
        local err, _
        value, err, _ = core.utils.resolve_var(value, ctx.var)
        if err then
            return nil, "could not resolve var for value: " .. value ", err: " .. err
        end
        value = tonumber(value)
        if not value then
            return nil, "resolved value is not a number: " .. tostring(value)
        end
    end
    return value
end


local function get_rules(ctx, conf)
    if not conf.rules then
        local count, err = resolve_var(ctx, conf.count)
        if err then
            return nil, err
        end
        local time_window, err2 = resolve_var(ctx, conf.time_window)
        if err2 then
            return nil, err2
        end
        return {
            {
                count = count,
                time_window = time_window,
                key = conf.key,
                key_type = conf.key_type,
            }
        }
    end

    local rules = {}
    for index, rule in ipairs(conf.rules) do
        local count, err = resolve_var(ctx, rule.count)
        if err then
            goto CONTINUE
        end
        local time_window, err2 = resolve_var(ctx, rule.time_window)
        if err2 then
            goto CONTINUE
        end
        local key, _, n_resolved = core.utils.resolve_var(rule.key, ctx.var)
        if n_resolved == 0 then
            goto CONTINUE
        end
        core.table.insert(rules, {
            count = count,
            time_window = time_window,
            key_type = "constant",
            key = key,
            header_prefix = rule.header_prefix or index
        })

        ::CONTINUE::
    end
    return rules
end

local function construct_rate_limiting_headers(conf, name, rule, metadata)
    local prefix = "X-"
    if name == "ai-rate-limiting" then
        prefix = "X-AI-"
    end

    if rule.header_prefix then
        return {
            limit_header = prefix .. rule.header_prefix .. "-RateLimit-Limit",
            remaining_header = prefix .. rule.header_prefix .. "-RateLimit-Remaining",
            reset_header = prefix .. rule.header_prefix .. "-RateLimit-Reset",
        }
    end
    return  {
        limit_header = conf.limit_header or metadata.limit_header,
        remaining_header = conf.remaining_header or metadata.remaining_header,
        reset_header = conf.reset_header or metadata.reset_header,
    }
end

local function run_rate_limit(conf, rule, ctx, name, cost, dry_run)
    local lim, err = create_limit_obj(conf, rule, name)

    if not lim then
        core.log.error("failed to fetch limit.count object: ", err)
        if conf.allow_degradation then
            return
        end
        return 500
    end
    core.log.debug("limit object: ", core.json.delay_encode(lim, true))

    local conf_key = rule.key
    local key
    if rule.key_type == "var_combination" then
        local err, n_resolved
        key, err, n_resolved = core.utils.resolve_var(conf_key, ctx.var)
        if err then
            core.log.error("could not resolve vars in ", conf_key, " error: ", err)
        end

        if n_resolved == 0 then
            key = nil
        end
    elseif rule.key_type == "constant" then
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
        delay, remaining, reset = lim:incoming(key, cost, not dry_run)
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

    local set_limit_headers = construct_rate_limiting_headers(conf, name, rule, metadata)
    local phase = get_phase()
    local set_header = phase ~= "log"

    if not delay then
        local err = remaining
        if err == "rejected" then
            -- show count limit header when rejected
            if conf.show_limit_quota_header and set_header then
                core.response.set_header(set_limit_headers.limit_header, lim.limit,
                    set_limit_headers.remaining_header, 0,
                    set_limit_headers.reset_header, reset)
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

    if conf.show_limit_quota_header and set_header then
        core.response.set_header(set_limit_headers.limit_header, lim.limit,
            set_limit_headers.remaining_header, remaining,
            set_limit_headers.reset_header, reset)
    end
end


function _M.rate_limit(conf, ctx, name, cost, dry_run)
    core.log.info("ver: ", ctx.conf_version)

    local rules, err = get_rules(ctx, conf)
    if not rules or #rules == 0 then
        core.log.error("failed to get rate limit rules: ", err)
        if conf.allow_degradation then
            return
        end
        return 500
    end

    for _, rule in ipairs(rules) do
        local code, msg = run_rate_limit(conf, rule, ctx, name, cost, dry_run)
        if code then
            return code, msg
        end
    end
end


return _M
