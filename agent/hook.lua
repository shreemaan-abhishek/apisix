local require = require
-- set the JIT options before any code, to prevent error "changing jit stack size is not
-- allowed when some regexs have already been compiled and cached"
if require("ffi").os == "Linux" then
    local ngx_re = require("ngx.re")
    local old_ngx_re_opt = ngx_re.opt
    old_ngx_re_opt("jit_stack_size", 200 * 1024)

    -- skip any subsequent settings for "jit_stack_size" to avoid
    -- the "changing jit stack size is not allowed" error.
    -- This behavior might be executed by Apache APISIX core.
    ngx_re.opt = function(option, value)
        if option == "jit_stack_size" then
            return
        end

        old_ngx_re_opt(option, value)
    end
end


local config_dict = ngx.shared.config
local function get_config_from_dict(key, default)
    local value, err = config_dict:get(key)
    if err then
        core.log.error("failed to get key from dict: ", err)
        return default
    end

    return value or default
end

-- Rewrite the config_local.local_conf, now we will merge the config from control plane and local file.
-- In heartbeats API, we will set the config_version and config_payload to the shared dict.
-- config_version means the version of the config from control plane.It starts from 1.
-- config_payload means the config from control plane.The format is same as the local file.
-- @param force: force to reload the config from control plane.
local config_local = require("apisix.core.config_local")
local json = require("apisix.core.json")
local file = require("agent.file")
local log = require("apisix.core.log")
local config_version = 0
local config_data
local old_local_conf = config_local.local_conf
config_local.local_conf = function(force)
    local latest_config_version = get_config_from_dict("config_version", 0)
    if not force and config_data then
        if latest_config_version <= config_version then
            return config_data
        end
    end

    local default_conf, err = old_local_conf(force)
    if not default_conf then
        return nil, err
    end

    --- Enable the kubernetes discovery by default.
    local latest_config_payload = get_config_from_dict("config_payload", "{\"discovery\": {\"kubernetes\": []}}")
    if not latest_config_payload then
        return default_conf
    end

    local config_data_from_control_plane, err = json.decode(latest_config_payload)
    if err then
        return nil, err
    end

    -- clone default_conf to avoid modifying the default_conf
    config_data = table.clone(default_conf)

    local ok, err = file.merge_conf(config_data, config_data_from_control_plane)
    if not ok then
        return nil, err
    end

    config_version = latest_config_version

    log.info("succeed to merge the config from control plane, version: ", config_version)
    return config_data
end

require("apisix.patch").patch()

local core = require("apisix.core")
core.id.init()

local agent = require("agent.agent")
local getenv = os.getenv
local api7_agent

local function hook()
    local local_conf = config_local.local_conf()
    local etcd_conf = core.table.try_read_attr(local_conf, "deployment", "etcd")

    local gateway_group_id = getenv("API7_CONTROL_PLANE_GATEWAY_GROUP_ID")
    if not gateway_group_id or gateway_group_id == "" then
        gateway_group_id = "default"
    end

    local endpoint = getenv("API7_CONTROL_PLANE_ENDPOINT_DEBUG")
    if not endpoint or endpoint == "" then
        endpoint = etcd_conf.host[1]
    end

    local max_metrics_size = 1024 * 1024 * 32
    local max_metrics_size_str = getenv("API7_CONTROL_PLANE_MAX_METRICS_SIZE_DEBUG")
    if max_metrics_size_str and max_metrics_size_str ~= "" then
        max_metrics_size = tonumber(max_metrics_size_str)
    end

    api7_agent = agent.new({
        endpoint = endpoint,
        ssl_cert_path = etcd_conf.ssl_cert_path,
        ssl_key_path = etcd_conf.ssl_key_path,
        gateway_group_id = gateway_group_id,
        max_metrics_size = max_metrics_size,
    })


    local skip_first_heartbeat = getenv("API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG")
    if skip_first_heartbeat == "true" then
        return
    end

    for i = 1, 3 do
        err = api7_agent:heartbeat(true)
        if err == nil then
            break
        end

        if err then
            core.log.error("failed to send first heartbeat ", err)
        end
    end
end

hook()

local heartbeat_timer_name = "plugin#api7-agent#heartbeat"
local telemetry_timer_name = "plugin#api7-agent#telemetry"

local heartbeat = function()
    api7_agent:heartbeat()
end

local upload_metrics = function()
    api7_agent:upload_metrics()
end

local apisix = require("apisix")
local old_http_init_worker = apisix.http_init_worker
apisix.http_init_worker = function(...)
    local pcall = pcall
    ok, res = pcall(old_http_init_worker, ...)
    if not ok then
      core.log.error("failed to init worker, the data plane instance will be automatically exited soon, error: ", res)
    end

    local timers  = require("apisix.timers")
    timers.register_timer(heartbeat_timer_name, heartbeat, true)
    timers.register_timer(telemetry_timer_name, upload_metrics, true)
end

return _M
