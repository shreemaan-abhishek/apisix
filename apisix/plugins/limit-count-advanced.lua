local fetch_secrets = require("apisix.secret").fetch_secrets
local limit_count = require("apisix.plugins.limit-count-advanced.init")
local workflow = require("apisix.plugins.workflow")

local plugin_name = "limit-count-advanced"
local _M = {
    version = 0.4,
    priority = 1001,
    name = plugin_name,
    schema = limit_count.schema,
    metadata_schema = limit_count.metadata_schema,
}


function _M.check_schema(conf, schema_type)
    return limit_count.check_schema(conf, schema_type)
end


function _M.access(conf, ctx)
    conf = fetch_secrets(conf, true, conf, "")
    return limit_count.rate_limit(conf, ctx, plugin_name, 1)
end


function _M.workflow_handler()
    workflow.register(plugin_name,
    function (conf)
        return limit_count.check_schema(conf)
     end,
    function (conf, ctx)
        return limit_count.rate_limit(conf, ctx, plugin_name, 1)
    end)
end


return _M
