local core = require("apisix.core")
local error = error
local ngx_decode_base64 = ngx.decode_base64

local custom_plugins

local _M = {}

local custom_plugin_schema = {
    type = "object",
    properties = {
        name = {type = "string"},
        content = {type = "string"},
    },
    required = {"name", "content"}
}

local function checker(conf)
    local content = ngx_decode_base64(conf.content)
    if not content then
        content = conf.content
    end
    local _, err = load(content)
    if err then
        return nil, "failed to load plugin string" .. err
    end

    return true
end

function _M.init_worker()
    if not custom_plugins then
        local err
        local plugin_pkg
        custom_plugins, err = core.config.new("/custom_plugins", {
            automatic = true,
            item_schema = custom_plugin_schema,
            checker = checker,
            filter = function(item)
                if not plugin_pkg then
                    plugin_pkg = require("apisix.plugin")
                end
                if item.value and item.value.name then
                    plugin_pkg.refresh_plugin(item.value.name, nil, nil, true)
                end
            end
        })

        if not custom_plugins then
            error("failed to sync /custom_plugins: " .. err)
            return
        end
    end
end

function _M.custom_plugins()
    if not custom_plugins then
        return nil, nil
    end

    return custom_plugins.values, custom_plugins.conf_version
end

function _M.get(id)
    if not custom_plugins then
        return
    end

    return custom_plugins:get(id)
end

return _M
