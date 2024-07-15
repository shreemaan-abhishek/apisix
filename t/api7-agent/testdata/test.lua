local core = require("apisix.core")
local pairs       = pairs
local type        = type
local ngx         = ngx

local schema = {
    type = "object",
    properties = {
        body = {
            description = "body to replace upstream response.",
            type = "string"
        },
    },
    anyOf = {
        {required = {"body"}},
    },
    minProperties = 1,
}

local plugin_name = "test"

local _M = {
    version = 0.1,
    priority = 412,
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end

    return true
end


function _M.body_filter(conf, ctx)
    if conf.body then
        ngx.arg[1] = "binary test"
        ngx.arg[2] = true
    end
end


function _M.header_filter(conf, ctx)
    if conf.body then
        core.response.clear_header_as_body_modified()
    end
end

return _M

