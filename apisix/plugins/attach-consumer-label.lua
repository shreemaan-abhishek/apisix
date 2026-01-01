local core = require("apisix.core")
local pairs = pairs
local plugin_name = "attach-consumer-label"

local schema = {
    type = "object",
    properties = {
        headers = {
            type = "object",
            additionalProperties = {
                type = "string",
                pattern = "^\\$.*"
            },
            minProperties = 1
        },
    },
    required = {"headers"},
}

local _M = {
    version = 0.1,
    priority = 2399,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.before_proxy(conf, ctx)
    -- check if the consumer is exists in the context
    if not ctx.consumer then
        return
    end

    local labels = ctx.consumer.labels
    core.log.info("consumer username: ", ctx.consumer.username, " labels: ",
            core.json.delay_encode(labels))
    if not labels then
        return
    end

    for header, label_key in pairs(conf.headers) do
        -- remove leading $ character
        local label_value = labels[label_key:sub(2)]
        core.request.set_header(ctx, header, label_value)
    end
end

return _M
