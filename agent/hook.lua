local require = require

local getenv = os.getenv
local log = require("apisix.core.log")

local control_plane_token = getenv("API7_CONTROL_PLANE_TOKEN")
if not control_plane_token then
    ngx.log(ngx.WARN, "missing API7_CONTROL_PLANE_TOKEN, the gateway will not connect to control plane")
    return
end

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

local AUTH_HEADER = "Control-Plane-Token"

local function update_conf_for_etcd(etcd_conf)
    if not etcd_conf then
        return
    end

    if not etcd_conf.extra_headers then
        etcd_conf.extra_headers = {}
    end

    etcd_conf.extra_headers[AUTH_HEADER] = getenv("API7_CONTROL_PLANE_TOKEN")

    return etcd_conf
end


local shdict_name = "config"
if ngx.config.subsystem == "stream" then
    shdict_name = shdict_name .. "-stream"
end
local config_dict   = ngx.shared[shdict_name]
local function get_config_from_dict(key, default)
    local value, err = config_dict:get(key)
    if err then
        log.error("failed to get key from dict: ", err)
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
local util = require("apisix.cli.util")
local constants = require("apisix.constants")

local config_version = 0
local config_data
local old_local_conf = config_local.local_conf
config_local.local_conf = function(force)
    local latest_config_version = get_config_from_dict("config_version", 0)
    if not force and config_data then
        if latest_config_version <= config_version then
            log.info("found cached config_data in hook")
            return config_data
        end
    end

    local default_conf, err = old_local_conf(force)
    if not default_conf then
        log.error("failed to get default_conf: ", err)
        return nil, err
    end

    -- if disable the admin API if connect to the control plane
    if default_conf and default_conf.apisix then
        default_conf.apisix.enable_admin = false
    end

    --- Enable the kubernetes discovery by default.
    local latest_config_payload = get_config_from_dict("config_payload", "{\"api7_discovery\": {\"kubernetes\": [], \"nacos\": []}}")
    if not latest_config_payload then
        log.warn("couldnt find config payload in shdict")
        return default_conf
    end

    local config_data_from_control_plane, decode_err
    if default_conf.deployment.config_provider == "yaml" then
        local dp_config, err = util.read_file(constants.DP_CONF_FILE)
        if not dp_config then
            log.error("failed to read dp_config file: ", err)
            return nil, err
        end
        local config
        config, decode_err = json.decode(dp_config)
        config_data_from_control_plane = config.config and config.config.config_payload
    else
        config_data_from_control_plane, decode_err = json.decode(latest_config_payload)
    end

    if not config_data_from_control_plane then
        log.error("failed to parse dp_config data: ", decode_err)
        return nil, decode_err
    end

    -- clone default_conf to avoid modifying the default_conf
    config_data = table.clone(default_conf)

    local ok, err = file.merge_conf(config_data, config_data_from_control_plane)
    if not ok then
        log.error("failed to get merge conf: ", err)
        return nil, err
    end

    config_data.etcd = update_conf_for_etcd(config_data.etcd)
    config_version = latest_config_version

    log.info("succeed to merge the config from control plane, version: ", config_version)
    return config_data
end

require("apisix.patch").patch()

local core = require("apisix.core")
core.id.init()

-- replace the apisix.discovery.init to agent.discovery.init
local wrapper = require("agent.discovery.wrapper")
package.loaded["apisix.discovery.init"] = wrapper

local agent = require("agent.agent")
local getenv = os.getenv
local api7_agent

local function hook()
    local local_conf = config_local.local_conf()
    local etcd_conf = core.table.try_read_attr(local_conf, "deployment", "etcd")

    local endpoint = getenv("API7_CONTROL_PLANE_ENDPOINT_DEBUG")
    if not endpoint or endpoint == "" then
        endpoint = etcd_conf.host[1]
    end

    local max_metrics_size = 1024 * 1024 * 32
    local max_metrics_size_str = getenv("API7_CONTROL_PLANE_MAX_METRICS_SIZE_DEBUG")
    if max_metrics_size_str and max_metrics_size_str ~= "" then
        max_metrics_size = tonumber(max_metrics_size_str)
    end

    local ssl_cert_path
    local ssl_key_path
    if etcd_conf.tls and etcd_conf.tls.cert then
        ssl_cert_path = etcd_conf.tls.cert
    end

    if etcd_conf.tls and etcd_conf.tls.key then
        ssl_key_path = etcd_conf.tls.key
    end

    local healthcheck_report_interval = core.table.try_read_attr(local_conf, "api7ee", "healthcheck_report_interval")
    if not healthcheck_report_interval then
        healthcheck_report_interval = 60 * 2
    end

    api7_agent = agent.new({
        endpoint = endpoint,
        ssl_cert_path = ssl_cert_path,
        ssl_key_path = ssl_key_path,
        max_metrics_size = max_metrics_size,
        healthcheck_report_interval = healthcheck_report_interval,
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
local report_healthcheck_timer_name = "plugin#api7-agent#report_healthcheck"

local heartbeat = function()
    api7_agent:heartbeat()
end

local upload_metrics = function()
    api7_agent:upload_metrics()
end

local report_healthcheck = function()
    api7_agent:report_healthcheck()
end

local apisix = require("apisix")
local old_http_init_worker = apisix.http_init_worker
apisix.http_init_worker = function(...)
    local pcall = pcall
    ok, res = pcall(old_http_init_worker, ...)
    if not ok then
      core.log.error("failed to init worker, the data plane instance will be automatically exited soon, error: ", res)
    end

    local plugin = require("apisix.plugin")
    plugin.init_plugins_syncer()

    if wrapper and wrapper.discovery then
        wrapper.discovery.init_worker()
    end

    if core.config.type == "etcd" then
        local timers  = require("apisix.timers")
        timers.register_timer(heartbeat_timer_name, heartbeat, true)
        timers.register_timer(telemetry_timer_name, upload_metrics, true)
        timers.register_timer(report_healthcheck_timer_name, report_healthcheck)
    else
        core.log.warn("skipped registering timer because config type: ", core.config.type)
    end
end
