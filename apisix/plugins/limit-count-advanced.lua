local fetch_secrets = require("apisix.secret").fetch_secrets
local limit_count = require("apisix.plugins.limit-count-advanced.init")

local plugin_name = "limit-count-advanced"
local _M = {
    version = 0.4,
    priority = 1001,
    name = plugin_name,
    schema = limit_count.schema,
}


function _M.check_schema(conf)
    return limit_count.check_schema(conf)
end


function _M.access(conf, ctx)
    conf = fetch_secrets(conf, true, conf, "")
    return limit_count.rate_limit(conf, ctx, plugin_name, 1)
end


return _M
