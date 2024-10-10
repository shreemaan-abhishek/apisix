local core   = require("apisix.core")
local apisix_upstream = require("apisix.upstream")
local plugin = require("apisix.plugin")
local services
local error = error


local _M = {
    version = 0.2,
}


function _M.get(service_id)
    return services:get(service_id)
end


function _M.services()
    if not services then
        return nil, nil
    end

    return services.values, services.conf_version
end


local function filter(service)
    service.has_domain = false
    if not service.value then
        return
    end

    apisix_upstream.filter_upstream(service.value.upstream, service)

    core.log.info("filter service: ", core.json.delay_encode(service, true))
end


local function service_checker(...)
    local args = {...}
    local item = args[1]
    if ngx.config.subsystem == "stream" and item.type == "stream" then
        return plugin.stream_plugin_checker(...)
    end

    if ngx.config.subsystem ~= "stream" and item.type ~= "stream" then
        return plugin.plugin_checker(...)
    end

    return true
end


function _M.init_worker()
    local err
    services, err = core.config.new("/services", {
        automatic = true,
        item_schema = core.schema.service,
        checker = service_checker,
        filter = filter,
    })
    if not services then
        error("failed to create etcd instance for fetching /services: " .. err)
        return
    end
end


return _M
