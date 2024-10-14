local agent = require("agent.agent")
local core = require("apisix.core")
local config_local = require("apisix.core.config_local")

-- instance of agent_api7
local _M = {}

local agent_api7
local function get_agent_api7()
    if not agent_api7 then
        agent_api7 = agent.get_agent("api7")
        if not agent_api7 then
            return nil, "not found agent api7"
        end
    end
    return agent_api7
end


local function release_consumer_cache(agent_api7)
    if not agent_api7 then
        return
    end

    local local_conf = config_local.local_conf()
    if local_conf.config_version and agent_api7.config_version < local_conf.config_version then
        agent_api7.config_version = local_conf.config_version
        local consumer_proxy = core.table.try_read_attr(local_conf, "api7ee", "consumer_proxy")
        agent_api7:set_consumer_cache(consumer_proxy)
        core.log.info("release consuemr cache, new config version: ", agent_api7.config_version)
    end
end


function _M.consumer_query(plugin_name, key_value)
    local agent_api7, err = get_agent_api7()
    if not agent_api7 then
        core.log.error("failed to get agent api7: ", err)
        return nil, err
    end

    release_consumer_cache(agent_api7)

    return agent_api7:consumer_query(plugin_name, key_value)
end


function _M.enabled_consumer_proxy()
    local local_conf = config_local.local_conf()
    local consumer_proxy = core.table.try_read_attr(local_conf, "api7ee", "consumer_proxy")
    return consumer_proxy and consumer_proxy.enable
end

return _M
