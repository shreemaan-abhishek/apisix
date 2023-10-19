-- local common libs
local getenv  = os.getenv
local require = require
local core    = require("apisix.core")
local plugin  = require("apisix.plugin")
local timers  = require("apisix.timers")
local agent   = require("apisix.plugins.api7-agent.agent")


local plugin_name = "api7-agent"

-- plugin schema
local plugin_schema = {
    type = "object",
    properties = {},
    required = {},
}

local plugin_attr_schema = {
    type = "object",
    properties = {
        endpoint = {
            type = "string",
        },
        max_metrics_size = {
            type = "integer",
            minimum = 1,
            default = 1024 * 1024 * 32,
        },
    },
}

local _M = {
    version     = 0.1,            -- plugin version
    priority    = 1,              -- the priority of this plugin will be 0
    name        = plugin_name,    -- plugin name
    schema      = plugin_schema,  -- plugin schema
    attr_schema = plugin_attr_schema,
}

local heartbeat_timer_name = "plugin#api7-agent#heartbeat"
local telemetry_timer_name = "plugin#api7-agent#telemetry"

local api7_agent


local heartbeat = function()
    api7_agent:heartbeat()
end


local upload_metrics = function()
    api7_agent:upload_metrics()
end


-- module interface for init phase
function _M.init()
    local plugin_attr = plugin.plugin_attr(plugin_name)
    plugin_attr = plugin_attr and core.table.clone(plugin_attr) or {}
    local ok, err = core.schema.check(plugin_attr_schema, plugin_attr)
    if not ok then
        core.log.error("failed to check the plugin_attr[", plugin_name, "]", ": ", err)
        return
    end

    core.log.info("plugin attribute: ", core.json.delay_encode(plugin_attr))

    local endpoint
    local etcd_cli = core.etcd.get_etcd_cli()
    if not etcd_cli then
        core.log.error("failed to get etcd_cli")
        return
    end
    if plugin_attr.endpoint then
        endpoint = plugin_attr.endpoint
    else
        if not etcd_cli.endpoints or #etcd_cli.endpoints == 0 or
            not etcd_cli.endpoints[1].http_host then
            core.log.error("failed to get etcd endpoint")
            return
        end

        endpoint = etcd_cli.endpoints[1].http_host
    end

    -- get gateway group id, set default if nil or empty
    local gateway_group_id = getenv("API7_CONTROL_PLANE_GATEWAY_GROUP_ID")
    if not gateway_group_id or gateway_group_id == "" then
        gateway_group_id = "default"
    end
    api7_agent = agent.new({
        endpoint         = endpoint,
        ssl_cert_path    = etcd_cli.ssl_cert_path,
        ssl_key_path     = etcd_cli.ssl_key_path,
        max_metrics_size = plugin_attr.max_metrics_size,
        gateway_group_id = gateway_group_id,
    })

    timers.register_timer(heartbeat_timer_name, heartbeat, true)
    timers.register_timer(telemetry_timer_name, upload_metrics, true)
end


-- module interface for schema check
-- @param `conf` user defined conf data
-- @param `schema_type` defined in `apisix/core/schema.lua`
-- @return <boolean>
function _M.check_schema(conf, schema_type)
    return core.schema.check(plugin_schema, conf)
end


return _M
