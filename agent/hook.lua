local require = require

local getenv = os.getenv
local log = require("apisix.core.log")
local ngx = ngx

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
local GATEWAY_INSTANCE_ID_HEADER = "Gateway-Instance-ID"
local RUN_ID_HEADER = "Gateway-Run-ID"
local GATEWAY_VERSION_HEADER = "Gateway-Version"

local id = require("apisix.core.id")
local run_id
local gateway_version = require("apisix.core.version").VERSION

local function update_conf_for_etcd(etcd_conf)
    if not etcd_conf then
        return
    end

    if not etcd_conf.extra_headers then
        etcd_conf.extra_headers = {}
    end
    -- dependent: https://github.com/api7/lua-resty-etcd/blob/ea0f4abe9cb3c00b6c6e6845f7a36ec2db27cf63/lib/resty/etcd/v3.lua#L213-L220
    -- Every time etcd sends a request, it dynamically retrieves the header of function v, regardless of whether local_conf is called.
    setmetatable(etcd_conf.extra_headers, {
        __pairs = function(t)
            local function iter(t, k)
                local k, v = next(t, k)
                if type(v) == "function" then
                    return k, v()
                end
                return k, v
            end
            return iter, t, nil
        end
    })

    etcd_conf.extra_headers[GATEWAY_INSTANCE_ID_HEADER] = id.get
    etcd_conf.extra_headers[AUTH_HEADER] = getenv("API7_DP_MANAGER_TOKEN")
                                            or getenv("API7_CONTROL_PLANE_TOKEN")
    if run_id then
        etcd_conf.extra_headers[RUN_ID_HEADER] = run_id
    end
    etcd_conf.extra_headers[GATEWAY_VERSION_HEADER] = gateway_version

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
            log.debug("found cached config_data in hook")
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
    if default_conf.deployment.config_provider == "yaml" or
       default_conf.deployment.config_provider == "json" then
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
    if config_data.etcd then
        log.info("conf for etcd updated, the extra header ", GATEWAY_INSTANCE_ID_HEADER, ": ",
                config_data.etcd.extra_headers[GATEWAY_INSTANCE_ID_HEADER]())
    end

    config_version = latest_config_version

    config_data.config_version = config_version

    log.info("succeed to merge the config from control plane, version: ", config_version)
    return config_data
end

require("apisix.patch").patch()
local uuid = require('resty.jit-uuid')
uuid.seed()
run_id = uuid.generate_v4()

local core = require("apisix.core")
core.id.init()

-- replace the apisix.discovery.init to agent.discovery.init
local wrapper = require("agent.discovery.wrapper")
package.loaded["apisix.discovery.init"] = wrapper

local agent = require("agent.agent")
local getenv = os.getenv
local api7_agent
local backup_mode = require("agent.backup_mode")

local function hook()
    local local_conf = config_local.local_conf()
    local etcd_conf = core.table.try_read_attr(local_conf, "deployment", "etcd")
    local ssl_conf = core.table.try_read_attr(local_conf, "apisix", "ssl")

    local endpoint = getenv("API7_DP_MANAGER_ENDPOINT_DEBUG")
    if not endpoint or endpoint == "" then
        endpoint = etcd_conf.host[1]
    end

    local ssl_cert_path
    local ssl_key_path
    local ssl_ca_cert
    local ssl_server_name = etcd_conf.tls and etcd_conf.tls.sni
    local verify = false
    local ssl_verify = "none"
    if etcd_conf.tls and etcd_conf.tls.cert then
        ssl_cert_path = etcd_conf.tls.cert
        verify = true
    end

    if etcd_conf.tls and etcd_conf.tls.key then
        ssl_key_path = etcd_conf.tls.key
        verify = true
    end

    if not etcd_conf.tls.verify then
        verify = false
    end

    if verify then
        ssl_ca_cert = ssl_conf and ssl_conf.ssl_trusted_certificate
        ssl_verify = ssl_ca_cert and "peer" or "none"
    end

    local consumer_proxy = core.table.try_read_attr(local_conf, "api7ee", "consumer_proxy")
    local developer_proxy = core.table.try_read_attr(local_conf, "api7ee", "developer_proxy")
    local heartbeat_interval = core.table.try_read_attr(local_conf, "api7ee", "heartbeat_interval")
    local backup_interval = core.table.try_read_attr(local_conf, "deployment", "fallback_cp", "interval")

    local healthcheck_report_interval = core.table.try_read_attr(local_conf, "api7ee", "healthcheck_report_interval")
    if not healthcheck_report_interval then
        healthcheck_report_interval = 60 * 2
    end


    local http_timeout = core.table.try_read_attr(local_conf, "api7ee", "http_timeout")
    if not http_timeout then
        http_timeout = "30s"
    end

    local telemetry = core.table.try_read_attr(local_conf, "api7ee", "telemetry")
    if not telemetry then
        telemetry = {}
    end
    if telemetry.enable == nil then
        telemetry.enable = true
    end
    if telemetry.interval == nil then
        telemetry.interval = 15
    end
    if telemetry.max_metrics_size == nil then
        telemetry.max_metrics_size = 1024 * 1024 * 32
    end

    api7_agent = agent.new({
        name = "api7",
        endpoint = endpoint,
        ssl_cert_path = ssl_cert_path,
        ssl_key_path = ssl_key_path,
        ssl_verify = ssl_verify,
        ssl_ca_cert = ssl_ca_cert,
        telemetry = telemetry,
        ssl_server_name = ssl_server_name,
        healthcheck_report_interval = healthcheck_report_interval,
        http_timeout = http_timeout,
        consumer_proxy = consumer_proxy,
        developer_proxy = developer_proxy,
        heartbeat_interval = heartbeat_interval,
        backup_interval = backup_interval or 60,
        run_id = run_id,
    })

    local skip_first_heartbeat = getenv("API7_SKIP_FIRST_HEARTBEAT_DEBUG")
    if skip_first_heartbeat == "true" then
        return
    end

    local succeed = false
    for i = 1, 3 do
        local err = api7_agent:heartbeat(true)
        if err == nil then
            succeed = true
            break
        end

        if err then
            core.log.error("failed to send heartbeat to control plane, ", err)
        end
    end
    if not succeed then
        error("failed to connect with control plane after 3 attempts, exiting...")
    end
end

hook()

local heartbeat_timer_name = "plugin#api7-agent#heartbeat"
local telemetry_timer_name = "plugin#api7-agent#telemetry"
local report_healthcheck_timer_name = "plugin#api7-agent#report_healthcheck"
local backup_configuration_timer_name = "plugin#api7-agent#backup_configuration"

local heartbeat = function()
    api7_agent:heartbeat()
end

local upload_metrics = function()
    api7_agent:upload_metrics()
end

local report_healthcheck = function()
    api7_agent:report_healthcheck()
end

local backup_configuration = function()
    backup_mode.backup_configuration(api7_agent)
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
        if api7_agent.telemetry.enable then
            timers.register_timer(telemetry_timer_name, upload_metrics, true)
            core.log.info("registered timer to send telemetry data to control plane")
        else
            core.log.info("disabled send telemetry data to control plane")
        end
        timers.register_timer(report_healthcheck_timer_name, report_healthcheck)
        if ngx.config.subsystem ~= "stream" then
            timers.register_timer(backup_configuration_timer_name, backup_configuration, true)
        end
    else
        core.log.warn("skipped registering timer because config type: ", core.config.type)
    end
end

local old_http_log_phase = apisix.http_log_phase
local status_counts_dict = ngx.shared["api-calls-by-status"]
if ngx.config.subsystem == "http" and not status_counts_dict then
    error('shared dict "api-calls-by-status" not defined')
end

apisix.http_log_phase = function (...)
    local status = ngx.status
    local _, err = status_counts_dict:incr(status, 1, 0)
    if err then
        core.log.error("failed to increase ", status, " in dict, error: ", err)
    end
    old_http_log_phase(...)
end

local old_stream_init_worker = apisix.stream_init_worker
apisix.stream_init_worker = function(...)
    local pcall = pcall
    ok, res = pcall(old_stream_init_worker, ...)
    if not ok then
      core.log.error("failed to init worker, the data plane instance will be automatically exited soon, error: ", res)
    end
    if core.config.type == "etcd" then
        local timers  = require("apisix.timers")
        timers.register_timer(report_healthcheck_timer_name, report_healthcheck)
    else
        core.log.warn("skipped registering timer because config type: ", core.config.type)
    end
end
