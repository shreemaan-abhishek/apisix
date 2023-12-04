local log          = require("apisix.core.log")
local pairs        = pairs

-- Now we only support "kubernetes" discovery type
local discovery_type = {"kubernetes"}
local discovery = {}

local _M = {
    version = 0.1,
    discovery = discovery
}

if discovery_type then
    for _, discovery_name in pairs(discovery_type) do
        log.info("use discovery: ", discovery_name)

        discovery[discovery_name] = require("agent.discovery." .. discovery_name)
    end
end

function _M.init_worker()
    if discovery_type then
        for _, discovery_name in pairs(discovery_type) do
            discovery[discovery_name].init_worker()
        end
    end
end

function _M.list_all_services()
    local services = {}
    if discovery_type then
        for _, discovery_name in pairs(discovery_type) do
            local service = discovery[discovery_name].list_all_services()
            for k, v in pairs(service) do
                services[k] = v
            end
        end
    end

    return services
end

function _M.get_health_checkers()
    local health_checkers = {}
    if discovery_type then
        for _, discovery_name in pairs(discovery_type) do
            local health_checker = discovery[discovery_name].get_health_checkers()
            for k, v in pairs(health_checker) do
                health_checkers[k] = v
            end
        end
    end

    return health_checkers
end

return _M
