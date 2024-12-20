local core = require("apisix.core")
local plugin = require("apisix.plugin")
local ngx = ngx

local metadata_schema = {
    type = "object",
    properties = {
        enable = { type = "boolean", default = false },
        body = {
            description = "body to replace upstream response.",
            type = "string"
        },
    },
    required = { "body" },
    minProperties = 1,
    encrypt_fields = {"body"},
}

local schema = {}

local plugin_name = "test-metadata"

local _M = {
    version = 0.1,
    priority = 413,
    name = plugin_name,
    schema = schema,
    metadata_schema = metadata_schema
}

function _M.check_schema(conf, schema_type)
    if schema_type == core.schema.TYPE_METADATA then
        return core.schema.check(metadata_schema, conf)
    end
    return core.schema.check(schema, conf)
end

local function get_metadata()
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

    return metadata
end

function _M.header_filter(conf, ctx)
    ctx.metadata = get_metadata()
    if not ctx.metadata then
        return
    end
    core.response.clear_header_as_body_modified()
end

function _M.body_filter(conf, ctx)
    if not ctx.metadata then
        return
    end

    ngx.arg[1] = ctx.metadata.body
    ngx.arg[2] = true
end

return _M
