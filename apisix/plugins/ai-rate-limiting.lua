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
local require = require
local setmetatable = setmetatable
local getmetatable = getmetatable
local ipairs = ipairs
local type = type
local expr = require("resty.expr.v1")
local core = require("apisix.core")
local limit_count = require("apisix.plugins.limit-count.init")

local plugin_name = "ai-rate-limiting"

local instance_limit_schema = {
    type = "object",
    properties = {
        name = {type = "string"},
        expr = {type = "array" },
        limit = {type = "integer", minimum = 1},
        time_window = {type = "integer", minimum = 1}
    },
    required = {"limit", "time_window"},
    oneOf = {
        {required = {"name"}},
        {required = {"expr"}},
    }
}

local schema = {
    type = "object",
    properties = {
        limit = {type = "integer", exclusiveMinimum = 0},
        time_window = {type = "integer",  exclusiveMinimum = 0},
        show_limit_quota_header = {type = "boolean", default = true},
        limit_strategy = {
            type = "string",
            enum = {"total_tokens", "prompt_tokens", "completion_tokens"},
            default = "total_tokens",
            description = "The strategy to limit the tokens"
        },
        instances = {
            type = "array",
            items = instance_limit_schema,
            minItems = 1,
        },
        rejected_code = {
            type = "integer", minimum = 200, maximum = 599, default = 503
        },
        rejected_msg = {
            type = "string", minLength = 1
        },
    },
    dependencies = {
        limit = {"time_window"},
        time_window = {"limit"}
    },
    anyOf = {
        {
            required = {"limit", "time_window"}
        },
        {
            required = {"instances"}
        }
    }
}

local _M = {
    version = 0.1,
    priority = 1030,
    name = plugin_name,
    schema = schema
}

local limit_conf_cache = core.lrucache.new({
    ttl = 300, count = 512
})


function _M.check_schema(conf)
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end

    for _, ins in ipairs(conf.instances or {}) do
        if ins.expr then
            local ok, err = expr.new(ins.expr)
            if not ok then
                return false, "failed to validate the 'expr' expression: " .. err
            end
        end
    end

    return true
end


local function transform_limit_conf(plugin_conf, instance_conf, instance_name)
    local key = plugin_name .. "#global"
    local limit = plugin_conf.limit
    local time_window = plugin_conf.time_window
    local name = instance_name or ""
    if instance_conf then
        name = instance_conf.name
        key = instance_conf.name
        limit = instance_conf.limit
        time_window = instance_conf.time_window
    end
    return {
        _vid = key,

        key = key,
        count = limit,
        time_window = time_window,
        rejected_code = plugin_conf.rejected_code,
        rejected_msg = plugin_conf.rejected_msg,
        show_limit_quota_header = plugin_conf.show_limit_quota_header,
        -- limit-count need these fields
        policy = "local",
        key_type = "constant",
        allow_degradation = false,
        sync_interval = -1,

        limit_header = "X-AI-RateLimit-Limit-" .. name,
        remaining_header = "X-AI-RateLimit-Remaining-" .. name,
        reset_header = "X-AI-RateLimit-Reset-" .. name,
    }
end


local function fetch_limit_conf_kvs(conf)
    -- use `conf.limit` as the global rate limit for instances that not found in `conf.instances`
    local mt = {
        __index = function(t, k)
            if not conf.limit then
                return nil
            end

            local limit_conf = transform_limit_conf(conf, nil, k)
            t[k] = limit_conf
            return limit_conf
        end
    }
    local limit_conf_kvs = setmetatable({}, mt)
    local conf_instances = conf.instances or {}
    for _, limit_conf in ipairs(conf_instances) do
        if limit_conf.name then
            limit_conf_kvs[limit_conf.name] = transform_limit_conf(conf, limit_conf)
        end
    end
    return limit_conf_kvs
end


function _M.access(conf, ctx)
    local ai_instance_name = ctx.picked_ai_instance_name
    if not ai_instance_name then
        core.log.warn("ai-rate-limiting plugin must be used with the ai-proxy[-multi] plugin")
        return
    end

    for i, ins in ipairs(conf.instances or {}) do
        if ins.expr then
            if not getmetatable(ins) then
                setmetatable(ins, {__index = {}})
            end
            local cache_data = getmetatable(ins).__index

            if not ins._expr_obj then
                cache_data._expr_obj = expr.new(ins.expr)
            end
            local matched = ins._expr_obj:eval(ctx.var)
            if matched then
                core.log.info("expr matched instance: ", core.json.delay_encode(ins))
                if not ins._limit_conf then
                    cache_data._limit_conf = transform_limit_conf(conf, {
                        name = "EXPR-" .. i,
                        limit = ins.limit,
                        time_window = ins.time_window,
                    })
                end
                ctx.ai_rate_limiting_matched_instance = ins
                local code, msg = limit_count.rate_limit(ins._limit_conf, ctx, plugin_name, 1, true)
                ctx.ai_rate_limiting = code and true or false
                return code, msg
            end
        end
    end

    local limit_conf_kvs = limit_conf_cache(conf, nil, fetch_limit_conf_kvs, conf)
    local limit_conf = limit_conf_kvs[ai_instance_name]
    if not limit_conf then
        return
    end
    local code, msg = limit_count.rate_limit(limit_conf, ctx, plugin_name, 1, true)
    ctx.ai_rate_limiting = code and true or false
    return code, msg
end


function _M.check_instance_status(conf, ctx, instance_name)
    if conf == nil then
        local plugins = ctx.plugins
        for i = 1, #plugins, 2 do
            if plugins[i]["name"] == plugin_name then
                conf = plugins[i + 1]
            end
        end
    end
    if not conf then
        return true
    end

    instance_name = instance_name or ctx.picked_ai_instance_name
    if not instance_name then
        return nil, "missing instance_name"
    end

    if type(instance_name) ~= "string" then
        return nil, "invalid instance_name"
    end

    local limit_conf_kvs = limit_conf_cache(conf, nil, fetch_limit_conf_kvs, conf)
    local limit_conf = limit_conf_kvs[instance_name]
    if not limit_conf then
        return true
    end

    local code, _ = limit_count.rate_limit(limit_conf, ctx, plugin_name, 1, true)
    if code then
        core.log.info("rate limit for instance: ", instance_name, " code: ", code)
        return false
    end
    return true
end


local function get_token_usage(conf, ctx)
    local usage = ctx.ai_token_usage
    if not usage then
        return
    end
    return usage[conf.limit_strategy]
end


function _M.log(conf, ctx)
    local instance_name = ctx.picked_ai_instance_name
    if not instance_name then
        return
    end

    if ctx.ai_rate_limiting then
        return
    end

    local used_tokens = get_token_usage(conf, ctx)
    if not used_tokens then
        core.log.error("failed to get token usage for llm service")
        return
    end

    if ctx.ai_rate_limiting_matched_instance then
        core.log.info("matched expr instance, used tokens: ", used_tokens)
        local limit_conf = ctx.ai_rate_limiting_matched_instance._limit_conf
        limit_count.rate_limit(limit_conf, ctx, plugin_name, used_tokens)
        return
    end

    core.log.info("instance name: ", instance_name, " used tokens: ", used_tokens)

    local limit_conf_kvs = limit_conf_cache(conf, nil, fetch_limit_conf_kvs, conf)
    local limit_conf = limit_conf_kvs[instance_name]
    if limit_conf then
        limit_count.rate_limit(limit_conf, ctx, plugin_name, used_tokens)
    end
end


return _M
