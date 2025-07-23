local ngx  = ngx
local core = require("apisix.core")
local require = require
local pairs = pairs
local type  = type
local ipairs = ipairs

local plugin = require("apisix.plugin")
local key_auth = require("apisix.plugins.key-auth")
local basic_auth = require("apisix.plugins.basic-auth")

local schema = {
    type = "object",
    title = "work with route or service object",
    properties = {
        api_product_id = {
            type = "string",
            minLength = 1,
            maxLength = 256,
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
                    }
                }
            },
            uniqueItems = true,
        }
    },
    required = { "auth_plugins" },
}


local plugin_name = "portal-auth"

local api_calls_for_portal_dict = ngx.shared["api-calls-for-portal"]
if not api_calls_for_portal_dict then
    error('shared dict "api-calls-for-portal" not defined')
end

local _M = {
    version = 0.1,
    priority = 2700,
    type = 'auth',
    name = plugin_name,
    schema = schema
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


local function execute_auth_plugins(auth_plugins, ctx)
    local errors = {}
    for _, auth_plugin in pairs(auth_plugins) do
        for auth_plugin_name, auth_plugin_conf in pairs(auth_plugin) do
            local auth = plugin.get(auth_plugin_name)
            -- returns 401 HTTP status code if authentication failed, otherwise returns nothing.
            local auth_code, err = auth.rewrite(auth_plugin_conf, ctx)
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
    if conf.api_product_id then
        ctx.api_product_id = conf.api_product_id
    end

    local succeed, errors = execute_auth_plugins(conf.auth_plugins, ctx)
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
        return
    end

    for _, err in ipairs(errors) do
        core.log.warn(err)
    end
    return 401, { message = "Authorization Failed" }
end

return _M
