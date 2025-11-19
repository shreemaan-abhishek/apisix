local ngx  = ngx
local core = require("apisix.core")
local require = require
local pairs = pairs
local type  = type
local ipairs = ipairs
local setmetatable = setmetatable

local expr    = require("resty.expr.v1")
local plugin = require("apisix.plugin")
local key_auth = require("apisix.plugins.key-auth")
local basic_auth = require("apisix.plugins.basic-auth")
local oidc = require("apisix.plugins.portal-auth.oidc")

local auth_methods = {
    oidc = oidc.auth,
}

local auth_rule_schema = {
    type = "object",
    title = "work with route or service object",
    properties = {
        portal_id = {
            type = "string",
            minLength = 1,
            maxLength = 256,
            default = "default",
        },
        api_product_id = {
            type = "string",
            minLength = 1,
            maxLength = 256,
        },
        case = {
            type = "array",
            items = {
                anyOf = {
                    {
                        type = "array",
                    },
                    {
                        type = "string",
                    },
                }
            },
            minItems = 1,
        },
        auth_plugins = {
            type = "array",
            minItems = 1,
            items = {
                oneOf = {
                    {
                        type = "object",
                        properties = { ["key-auth"] = key_auth.schema },
                        required = { "key-auth" }
                    },
                    {
                        type = "object",
                        properties = { ["basic-auth"] = basic_auth.schema },
                        required = { "basic-auth" }
                    },
                    {
                        type = "object",
                        properties = {
                            oidc = {
                                type = "object",
                                properties = {
                                    discovery = {
                                        type = "string",
                                    },
                                },
                                required = { "discovery" }
                            }
                        },
                        required = { "oidc" }
                    }
                }
            },
            uniqueItems = true,
        }
    },
    required = { "auth_plugins" },
}

local schema = {
    oneOf = {
        auth_rule_schema,
        {
            type = "object",
            properties = {
                rules = {
                    type = "array",
                    minItems = 1,
                    items = auth_rule_schema,
                },
            },
            required = { "rules" }
        }
    }
}


local plugin_name = "portal-auth"

local api_calls_for_portal_dict = ngx.shared["api-calls-for-portal"]
if not api_calls_for_portal_dict then
    error('shared dict "api-calls-for-portal" not defined')
end

local _M = {
    version = 0.1,
    priority = 2750,
    type = 'auth',
    name = plugin_name,
    schema = schema
}

function _M.check_schema(conf)
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end
    if not conf.rules then
        return true
    end

    for idx, rule in ipairs(conf.rules) do
        if rule.case then
            local _, err2 = expr.new(rule.case)
            if err2 then
                return false, "failed to validate the " .. idx  .. "th case: " .. err2
            end
        end
    end
    return true
end


local function execute_auth_plugins(auth_plugins, ctx)
    local errors = {}
    for _, auth_plugin in pairs(auth_plugins) do
        for auth_plugin_name, auth_plugin_conf in pairs(auth_plugin) do
            -- returns 401 HTTP status code if authentication failed, otherwise returns nothing.
            local auth_code, err
            if auth_methods[auth_plugin_name] then
                auth_code, err = auth_methods[auth_plugin_name](auth_plugin_conf, ctx)
            else
                local auth = plugin.get(auth_plugin_name)
                auth_code, err = auth.rewrite(auth_plugin_conf, ctx)
            end
            if auth_code == nil then
                core.log.info(auth_plugin_name, " succeed to authenticate the request")
                return true
            end
            if type(err) == "table" then
                err = err.message  -- compat
            end
            core.table.insert(errors, auth_plugin_name ..
                " failed to authenticate the request, code: "
                .. auth_code .. ". error: " .. err)
        end
    end
    return false, errors
end

function _M.log(conf, ctx)
    local consumer = ctx.consumer
    if consumer and consumer.labels then
        local subscription_id = consumer.labels.subscription_id
        local developer_id = consumer.labels.developer_id
        local application_id = consumer.labels.application_id
        local credential_id = consumer.credential_id
        local api_product_id = consumer.labels.api_product_id
        local status_code = ngx.status

        local key = subscription_id .. ":"
            .. developer_id .. ":"
            .. application_id .. ":"
            .. credential_id .. ":"
            .. api_product_id .. ":"
            .. status_code
        local _, err = api_calls_for_portal_dict:incr(key, 1, 0)
        if err then
            core.log.error("failed to increase api calls for ", key, ", err: ", err)
        end
    end
end

function _M.rewrite(conf, ctx)
    local matched_auth_rule
    if not conf.rules then
        matched_auth_rule = conf
    else
        for _, rule in ipairs(conf.rules) do
            local matched = true
            if rule.case then
                if not rule._expr then
                    core.log.debug("compiling case expression for portal auth rule, case: ",
                                        core.json.delay_encode(rule.case, true))
                    local caseExpr, _  = expr.new(rule.case)
                    setmetatable(rule, {__index = {
                        _expr = caseExpr,
                    }})
                end
                matched = rule._expr:eval(ctx.var)
            end
            if matched then
                matched_auth_rule = rule
                break
            end
        end
    end

    if not matched_auth_rule then
        core.log.info("no matching auth rule found")
        return
    end

    ctx.api_product_id = matched_auth_rule.api_product_id
    ctx.portal_id = matched_auth_rule.portal_id

    local succeed, errors = execute_auth_plugins(matched_auth_rule.auth_plugins, ctx)
    if succeed then
        local consumer = ctx.consumer
        if consumer.labels then
            core.request.set_header(ctx, "X-API7-Portal-Application-Id",
                                    consumer.labels.application_id)
            core.request.set_header(ctx, "X-API7-Portal-Developer-Id",
                                    consumer.labels.developer_id)
            core.request.set_header(ctx, "X-API7-Portal-Developer-Username",
                                    consumer.labels.developer_username)
            core.request.set_header(ctx, "X-API7-Portal-Subscription-Id",
                                    consumer.labels.subscription_id)
            core.request.set_header(ctx, "X-API7-Portal-API-Product-Id",
                                    consumer.labels.api_product_id)
        end
        core.request.set_header(ctx, "X-API7-Portal-Credential-Id", consumer.credential_id)
        core.request.set_header(ctx, "X-API7-Portal-Request-Id", ctx.var.apisix_request_id)
        core.request.set_header(ctx, "X-API7-Portal-Portal-Id", ctx.portal_id)
        return
    end

    for _, err in ipairs(errors) do
        core.log.warn(err)
    end
    return 401, { message = "Authorization Failed" }
end

return _M
