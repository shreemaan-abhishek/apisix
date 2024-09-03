local core     = require("apisix.core")
local plugins  = require("apisix.admin.plugins")
local plugin   = require("apisix.plugin")
local resource = require("apisix.admin.resource")
local pairs    = pairs

local function check_conf(_id, conf, _need_id, schema)
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return nil, {error_msg = "invalid configuration: " .. err}
    end

    if conf.plugins then
        ok, err = plugins.check_schema(conf.plugins, core.schema.TYPE_CONSUMER)
        if not ok then
            return nil, {error_msg = "invalid plugins configuration: " .. err}
        end

        for name, _ in pairs(conf.plugins) do
            local plugin_obj = plugin.get(name)
            if not plugin_obj then
                return nil, {error_msg = "unknown plugin " .. name}
            end
            if plugin_obj.type ~= "auth" then
                return nil, {error_msg = "only supports auth type plugins in consumer credential"}
            end
        end
    end

    return true, nil
end

local function get_key(_id, _conf, sub_path, _args)
    return "/consumers/" .. sub_path
end

return resource.new({
    name = "credentials",
    kind = "credential",
    schema = core.schema.credential,
    checker = check_conf,
    get_key = get_key,
    unsupported_methods = {"post", "patch"}
})
