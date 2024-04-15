local apisix_discovery = require("apisix.discovery.init")
local api7_discovery = require("agent.discovery.init")

local wrapper = {}

function wrapper.init_worker()
    apisix_discovery.discovery.init_worker()
    api7_discovery.discovery.init_worker()
end

local _M = {
    version = 0.1,
    discovery = setmetatable(wrapper, {
        __index = function(_, key)
            if apisix_discovery.discovery[key] then
                return apisix_discovery.discovery[key]
            end

            return api7_discovery.discovery[key]
        end
    })
}

return setmetatable(_M, { __index = api7_discovery })
