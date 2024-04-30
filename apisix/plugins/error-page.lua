local core        = require("apisix.core")
local plugin      = require("apisix.plugin")
local plugin_name = "error-page"
local ngx         = ngx
local format      = string.format

local function err_body(code)
    local tpl = [[
<html>
<head><title>%s</title></head>
<body>
<center><h1>%s</h1></center>
<hr><center>API7 Entreprise Edition</center>
</html>
]]
    return format(tpl, code, code)
end


local metadata_schema = {
    type = "object",
    properties = {
        enable = {type = "boolean", default = false},
        error_404 = {
            type = "object",
            properties = {
                body = {type = "string", default = err_body("404 Not Found")},
                content_type = {type = "string", default = "text/html"},
            }
        },
        error_500 = {
            type = "object",
            properties = {
                body = {type = "string", default = err_body("500 Internal Server Error")},
                content_type = {type = "string", default = "text/html"},
            }
        },
        error_502 = {
            type = "object",
            properties = {
                body = {type = "string", default = err_body("502 Bad Gateway")},
                content_type = {type = "string", default = "text/html"},
            }
        },
        error_503 = {
            type = "object",
            properties = {
                body = {type = "string", default = err_body("503 Service Unavailable")},
                content_type = {type = "string", default = "text/html"},
            }
        }
    },
}

local schema = {}

local _M = {
    version  = 0.1,
    priority = 450,
    name     = plugin_name,
    schema   = schema,
    metadata_schema = metadata_schema
}


function _M.check_schema(conf, schema_type)
    if schema_type == core.schema.TYPE_METADATA then
        return core.schema.check(metadata_schema, conf)
    end
    return core.schema.check(schema, conf)
end


-- return metadata only if the response should be modified
local function get_metadata(ctx)
    local status = ngx.status
    if ctx.var.upstream_status then
        return nil
    end

    if status < 404 then
        return nil
    end

    local metadata = plugin.plugin_metadata(plugin_name)
    if not metadata then
        core.log.info("failed to read metadata for ", plugin_name)
        return nil
    end
    core.log.info(plugin_name, " metadata: ", core.json.delay_encode(metadata))
    metadata = metadata.value
    if not metadata.enable then
        return nil
    end

    local err_page = metadata["error_" .. status]
    if not err_page or not (err_page.body and #err_page.body > 0) then
        core.log.info("error page for error_", status, " not defined, default will be used.")
        return nil
    end

    return metadata
end


function _M.header_filter(conf, ctx)
    ctx.plugin_error_page_meta = get_metadata(ctx)
    if not ctx.plugin_error_page_meta then
        return
    end
    local status = ngx.status
    core.response.set_header("content-type",
        ctx.plugin_error_page_meta["error_" .. status].content_type)
    core.response.set_header("content-length", #ctx.plugin_error_page_meta["error_" .. status].body)
end


function _M.body_filter(conf, ctx)
    if not ctx.plugin_error_page_meta then
        return
    end

    ngx.arg[1] = ctx.plugin_error_page_meta["error_" .. ngx.status].body
    ngx.arg[2] = true
end

return _M
