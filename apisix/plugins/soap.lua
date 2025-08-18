local ngx    = ngx
local core   = require("apisix.core")
local plugin = require("apisix.plugin")
local http   = require("resty.http")

local str_sub = string.sub
local str_lower = string.lower
local pairs = pairs

local schema = {
    type = "object",
    properties = {
        wsdl_url = core.schema.uri_def,
        keepalive = {
            type = "object",
            properties = {
                enable = {type = "boolean", default = true},
                timeout = {
                    type = "integer", -- in second
                    default = 30,
                    minimum = 10,
                },
                pool = {
                    type = "integer", -- pool size
                    default = 30,
                    minimum = 5,
                },
            },
        },
    },
    required = {"wsdl_url"},
}

local attr_schema = {
    type = "object",
    properties = {
        endpoint = {
            type = "string",
            default = "http://127.0.0.1:5000",
        },
        timeout = {
            type = "integer",
            minimum = 1,
            maximum = 60000,
            default = 3000,
            description = "timeout in milliseconds",
        },
    },
    required = {"endpoint"}
}

local plugin_name = "soap"

-- http://www.w3.org/Protocols/rfc2616/rfc2616-sec13.html#sec13.5.1
local HOP_BY_HOP_HEADERS = {
    ["connection"]          = true,
    ["keep-alive"]          = true,
    ["proxy-authenticate"]  = true,
    ["proxy-authorization"] = true,
    ["te"]                  = true,
    ["trailers"]            = true,
    ["transfer-encoding"]   = true,
    ["upgrade"]             = true,
    ["content-length"]      = true, -- Not strictly hop-by-hop, but Nginx will deal
                                    -- with this (may send chunked for example).
}

local _M = {
    version = 0.1,
    priority = 554,
    name = plugin_name,
    schema = schema,
    attr_schema = attr_schema,
}


function _M.check_schema(conf, schema_type)
    return core.schema.check(schema, conf)
end


function _M.init()
    local local_plugin_info = plugin.plugin_attr(plugin_name)
    local_plugin_info = local_plugin_info and core.table.clone(local_plugin_info) or {}
    local ok, err = core.schema.check(attr_schema, local_plugin_info)
    if not ok then
        core.log.error("failed to check the plugin_attr[", plugin_name, "]", ": ", err)
        return
    end
end


local function get_request_params(conf, ctx)
    local uri, args
    if ctx.var.upstream_uri == "" then
        -- use original uri instead of rewritten one
        uri = ctx.var.uri
    else
        uri = ctx.var.upstream_uri

        -- the rewritten one may contain new args
        local index = core.string.find(uri, "?")
        if index then
            local raw_uri = uri
            uri = str_sub(raw_uri, 1, index - 1)
            args = str_sub(raw_uri, index + 1)
        end
    end

    local headers = core.request.headers(ctx)
    headers["X-WSDL-URL"] = conf.wsdl_url
    -- force to use keepalive, avoid the influence of client connection: close
    headers["connection"] = nil

    local body, err = core.request.get_body()
    if err then
        core.log.error("failed to get request body: ", err)
        return nil
    end

    return {
        keepalive = conf.keepalive and conf.keepalive.enable or true,
        keepalive_timeout = conf.keepalive and
            (conf.keepalive.timeout * 1000) or 50000,
        keepalive_pool = conf.keepalive and conf.keepalive.pool or 10,

        path = uri,
        query = args or ctx.var.args,
        headers = headers,
        method = core.request.get_method(),
        body = body,
    }
end


function _M.access(conf, ctx)
    local plugin_attr = plugin.plugin_attr(plugin_name)
    if not plugin_attr then
        return 503, {message = "Missing soap plugin attr"}
    end

    local httpc = http.new()
    httpc:set_timeout(plugin_attr.timeout)

    local params = get_request_params(conf, ctx)
    if not params then
        return 400, {message = "Invalid request"}
    end

    local res, err = httpc:request_uri(plugin_attr.endpoint, params)
    if not res then
        core.log.error("failed to process soap request, err: ", err)
        return 503
    end

    -- Filter out hop-by-hop headers
    for k, v in pairs(res.headers) do
        if not HOP_BY_HOP_HEADERS[str_lower(k)] then
            core.response.set_header(k, v)
        end
    end

    ngx.header["Content-Type"] = "application/json"

    -- TODO: convert response body
    --  when soap-proxy outputs exception information
    return res.status, res.body
end


return _M
