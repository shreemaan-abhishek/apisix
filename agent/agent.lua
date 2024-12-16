local core    = require("apisix.core")
local socket  = require("socket")
local utils   = require("agent.utils")
local ltn12   = require("ltn12")
local https   = require("ssl.https")
local http    = require("socket.http")
local plugin  = require("apisix.plugin")
local plugin_checker = require("apisix.plugin").plugin_checker
local check_schema   = require("apisix.core.schema").check

local resty_http    = require("resty.http")
local discovery     = require("agent.discovery")
local lrucache      = require("resty.lrucache")

local get_health_checkers = require("apisix.control.v1").get_health_checkers
local plugin_decrypt_conf = plugin.decrypt_conf
local enable_gde = plugin.enable_gde

local setmetatable  = setmetatable
local ngx_time      = ngx.time
local str_format    = string.format
local get_phase     = ngx.get_phase
local getenv = os.getenv

local shdict_name = "config"
if ngx.config.subsystem == "stream" then
    shdict_name = shdict_name .. "-stream"
end
local config_dict   = ngx.shared[shdict_name]

local agents = {}

local _M = {}

local mt = {
    __index = _M
}

-- max_items same as https://github.com/apache/apisix/blob/77704832ec91117f5ca7171811ae5f0d3f1494fe/apisix/balancer.lua#L38-L40
local healthcheck_cache     = lrucache.new(1024 * 4)
local HEALTHCHECK_CACHE_TTL = 20 * 60 -- 20 min
local MAX_CONF_VERSION      = 100000000

local payload = {
    subsystem = ngx.config.subsystem,
    hostname = core.utils.gethostname(),
    ip = socket.dns.toip(core.utils.gethostname()),
    version = core.version.VERSION,
    ports = utils.get_listen_ports(),
}

local control_plane_token = getenv("API7_CONTROL_PLANE_TOKEN")
local AUTH_HEADER = "Control-Plane-Token"
local headers = {
    ["Content-Type"] = "application/json",
    [AUTH_HEADER] = control_plane_token,
}


local function request(req_params, conf, ssl)
    if not ssl then
        return http.request(req_params)
    end

    req_params.certificate = conf.cert
    req_params.key = conf.key
    req_params.cafile = conf.cafile
    req_params.verify = conf.verify or "none"

    return https.request(req_params)
end

local function send_request(url, opts)
    if get_phase() == "init" or get_phase() == "init_worker" then
        local response_body = {}
        local ssl = false
        if string.sub(url, 1, 5) == "https" then
            ssl = true
        end

        -- Lua does not verify the CN or SAN of the server certificate
        local resp_status, http_status = request({
            url = url,
            method = opts.method,
            source = ltn12.source.string(opts.body),
            sink = ltn12.sink.table(response_body),
            headers = opts.headers,
        }, {
            cert = opts.ssl_cert_path,
            key = opts.ssl_key_path,
            cafile = opts.ssl_ca_cert,
            verify = opts.ssl_verify,
        }, ssl)

        if not resp_status then
            return nil, "request " .. url .. " error ", http_status
        end

        return {
            body = response_body,
            status = http_status,
        }, nil
    end

    local http_cli = resty_http.new()

    http_cli:set_timeout(opts.http_timeout)
    local res, err = http_cli:request_uri(url, {
        method = opts.method,
        body = opts.body,
        headers = opts.headers,
        query = opts.query,
        keepalive = true,
        ssl_verify = opts.ssl_verify == "peer" and true or false,
        ssl_cert_path = opts.ssl_cert_path,
        ssl_key_path = opts.ssl_key_path,
        ssl_server_name = opts.ssl_server_name,
    })

    return res, err
end

function _M.heartbeat(self, first)
    local current_time = ngx_time()
    if self.last_heartbeat_time and
            current_time - self.last_heartbeat_time < self.heartbeat_interval then
        return
    end
    if self.ongoing_heartbeat then
        core.log.info("previous heartbeat request not finished yet")
        return
    end
    payload.run_id = self.run_id
    payload.api_calls = 0
    local api_calls, err = config_dict:get("api_calls_counter")
    if api_calls ~= nil then
        payload.api_calls = api_calls - self.api_calls_counter_last_value
    end

    if err ~= nil then
        core.log.error("failed get api_calls_counter from dict, error: ", err)
    end

    local uid = core.id.get()
    payload.control_plane_revision = utils.get_control_plane_revision()
    payload.cores = ngx.worker.count()
    payload.instance_id = uid

    local internal_services = discovery.list_all_services()

    payload.probe_result = {
        service_registries = internal_services,
    }

    local post_heartbeat_payload = core.json.encode(payload)
    self.ongoing_heartbeat = true
    local res, err = send_request(self.heartbeat_url, {
        method =  "POST",
        body = post_heartbeat_payload,
        headers = headers,
        http_timeout = self.http_timeout,
        ssl_verify = self.ssl_verify,
        ssl_ca_cert = self.ssl_ca_cert,
        ssl_cert_path = self.ssl_cert_path,
        ssl_key_path = self.ssl_key_path,
        ssl_server_name = self.ssl_server_name,
    })
    self.ongoing_heartbeat = false

    if not first then
        self.last_heartbeat_time = current_time
    end

    if not res then
        core.log.error("heartbeat failed ", err)
        return
    end

    if res.status ~= 200 then
        core.log.warn("heartbeat failed, status: " .. res.status .. ", body: ", core.json.encode(res.body))
        return
    end

    -- Reset counter only when heartbeat success.
    if api_calls ~= nil then
        self.api_calls_counter_last_value = api_calls
    end

    local resp_body, err = utils.parse_resp(res.body)
    if not resp_body then
        core.log.error("failed to parse response body: ", err)
        return
    end
    core.log.debug("heartbeat response: ", core.json.delay_encode(resp_body))

    local gateway_group_id = resp_body.gateway_group_id
    if not gateway_group_id then
        gateway_group_id = ""
        core.log.warn("missing gateway_group_id in heartbeat response from control plane")
    end

    local config = resp_body.config or {}
    local instance_id = resp_body.instance_id or uid
    config_dict:set("gateway_group_id", gateway_group_id)
    if config.config_version and config.config_version > self.config_version then
        core.log.info("config version changed, old version: ", self.config_version, ", new version: ", config.config_version)

        self.config_version = config.config_version
        config_dict:set("config_version", config.config_version)
        config_dict:set("config_payload", core.json.encode(config.config_payload))

        if not first then
            ok, res = pcall(discovery.discovery.init_worker)
            if ok then
                core.log.info("service discovery re-init successfully")
            else
                core.log.error("failed to re-init service discovery: ", res)
            end
        end
    end

    if instance_id ~= uid then
        core.log.warn("instance_id changed, old uid: ", uid, ", new uid: ", instance_id)
        core.id.set(instance_id)
    end

    local msg = str_format("dp instance \'%s\' heartbeat successfully", instance_id)

    core.log.info(msg)
end


function _M.upload_metrics(self)
    local current_time = ngx_time()
    if self.last_metrics_uploading_time and
            current_time - self.last_metrics_uploading_time < self.telemetry.interval then
        return
    end
    if self.ongoing_metrics_uploading then
        core.log.info("previous metrics upload request not finished yet")
        return
    end

    local payload = {
        instance_id = core.id.get(),
    }

    -- Since we should get the metrics of nginx status,
    -- and we can't start sub-request in timer,
    -- so we should send request to APISIX metrics port.
    local res, err = utils.fetch_metrics(self.http_timeout)
    if err then
        core.log.error("fetch prometheus metrics error ", err)
        return
    end
    if res.status ~= 200 then
        core.log.error("failed to fetch prometheus metrics, status: ", res.status)
        return
    end

    local metrics = res.body

    if #metrics > self.telemetry.max_metrics_size then
        core.log.warn("metrics size is too large, truncating it, size: ", #metrics, ", after truncated: ", self.telemetry.max_metrics_size)
        payload.truncated = true
        metrics = string.sub(metrics, 1, self.telemetry.max_metrics_size)
    end

    payload.metrics = metrics

    local http_cli = resty_http.new()

    http_cli:set_timeout(self.http_timeout)

    self.ongoing_metrics_uploading = true
    local res, err = http_cli:request_uri(self.metrics_url, {
        method =  "POST",
        body = core.json.encode(payload),
        headers = headers,
        keepalive = true,
        ssl_verify = false,
        ssl_cert_path = self.ssl_cert_path,
        ssl_key_path = self.ssl_key_path,
    })
    self.ongoing_metrics_uploading = false

    self.last_metrics_uploading_time = current_time
    local resp_body
    if not res then
        core.log.error("upload metrics failed ", err)
        return
    end

    if res.status ~= 200 then
        core.log.warn("upload metrics failed, status: " .. res.status .. ", body: ", core.json.encode(res.body))
        return
    end

    local msg = str_format("dp instance \'%s\' upload metrics to control plane successfully", payload.instance_id)
    core.log.info(msg)
end

local function push_healthcheck_data(self, url, data, kind)
    if #data == 0 then
        core.log.info(kind, "no new healthcheck data to report")
        return
    end

    local payload_data = core.json.encode({
        instance_id = core.id.get(),
        data = data
    })

    local res, err = send_request(url, {
        method = "POST",
        body = payload_data,
        headers = headers,
        http_timeout = self.http_timeout,
        ssl_verify = self.ssl_verify,
        ssl_ca_cert = self.ssl_ca_cert,
        ssl_cert_path = self.ssl_cert_path,
        ssl_key_path = self.ssl_key_path,
        ssl_server_name = self.ssl_server_name,
    })

    if not res then
        core.log.warn(kind, "report healthcheck data failed: ", err)
        return
    end

    if res.status ~= 200 then
        core.log.warn(kind, "report healthcheck data failed: payload: ", payload_data, ", response status: ", res.status,
                ", response body: ", core.json.encode(res.body))
        return
    end

    local msg = str_format("dp instance \'%s\' report healthcheck data successfully", payload.instance_id)
    core.log.info(kind, msg)
end


local function report_upstream_healthcheck(self)
    -- Control API in version 3.2
    -- https://apisix.apache.org/zh/docs/apisix/3.2/control-api/#get-v1healthcheck
    -- UPGRADE NOTICE:
    --   When upgrading APISIX DP, this needs to be redesigned because the return value of the control API has changed.
    local _, infos = get_health_checkers()
    if not infos or #infos == 0 then
        core.log.debug("no healthcheck data to report")
        return
    end

    local data = core.table.new(0, 0)
    for _, upstream in core.config_util.iterate_values(infos) do
        if not (upstream.src_type and upstream.src_id and upstream.src_type == "upstreams" and upstream.nodes) then
            goto continue
        end

        local all_nodes = {}
        for _, node in core.config_util.iterate_values(upstream.nodes) do
            local host = node.domain and #node.domain > 0 and node.domain or node.host
            local port = node.port
            if host and port then
                local node_key = host .. ":" .. port
                all_nodes[node_key] = {
                    host = host,
                    port = port,
                    status = "unhealthy"
                }
            end
        end

        for _, node in core.config_util.iterate_values(upstream.healthy_nodes) do
            local host = node.domain and #node.domain > 0 and node.domain or node.host
            local port = node.port
            if host and port then
                local node_key = host .. ":" .. port
                all_nodes[node_key] = {
                    host = host,
                    port = port,
                    status = "healthy"
                }
            end
        end

        local diff_nodes = {}
        for key, node in pairs(all_nodes) do
            local cache_key = upstream.src_id .. "_" .. key
            local prev_status = healthcheck_cache:get(cache_key)
            local cur_status = node.status
            if not prev_status or prev_status ~= cur_status then
                core.table.insert(diff_nodes, node)
            end
        end

        if #diff_nodes > 0 then
            core.table.insert(data, {
                upstream_id = upstream.src_id,
                nodes = diff_nodes
            })
        end

        :: continue ::
    end

    push_healthcheck_data(self, self.healthcheck_url, data, "[UPSTREAM] ")

    -- set cache
    for _, upstream in core.config_util.iterate_values(data) do
        for _, node in core.config_util.iterate_values(upstream.nodes) do
            local cache_key = upstream.upstream_id .. "_" .. node.host .. ":" .. node.port
            healthcheck_cache:set(cache_key, node.status, HEALTHCHECK_CACHE_TTL)
        end
    end
end


local function report_service_registry_healthcheck(self)
    local stats = discovery.get_health_checkers()
    local healthcheck_data = core.table.new(128, 0)
    for id, nodes in pairs(stats) do
        for _, stat in ipairs(nodes) do
            local counter = stat.counter
            if counter.http_failure >= 1 or counter.tcp_failure >= 1
                or counter.timeout_failure >= 1 or counter.success >= 2 then
                    core.table.insert(healthcheck_data,
                        {
                            service_registry_id = id,
                            status = (stat.status == "healthy") and 1 or 0,
                            hostname = payload.hostname,
                            time = ngx_time()
                        }
                    )
            end
        end
    end

    push_healthcheck_data(self, self.service_registry_healthcheck_url, healthcheck_data, "[SERVICE REGISTRY] ")
end


function _M.report_healthcheck(self)
    local current_time = ngx_time()
    if self.last_report_healthcheck_time and
            current_time - self.last_report_healthcheck_time < self.healthcheck_report_interval then
        return
    end

    self.last_report_healthcheck_time = current_time

    report_upstream_healthcheck(self)
    report_service_registry_healthcheck(self)
end


local function check_consumer(consumer)
    local data_valid, err = check_schema(core.schema.consumer, consumer)
    if not data_valid then
        return data_valid, err
    end

    return plugin_checker(consumer, core.schema.TYPE_CONSUMER)
end


local function fetch_consumer(self, url, query)
    local resp, err = send_request(url, {
        method =  "GET",
        query = query,
        headers = headers,
        http_timeout = self.http_timeout,
        ssl_verify = self.ssl_verify,
        ssl_ca_cert = self.ssl_ca_cert,
        ssl_cert_path = self.ssl_cert_path,
        ssl_key_path = self.ssl_key_path,
        ssl_server_name = self.ssl_server_name,
    })
    if not resp then
        core.log.error("failed to fetch consumer from control plane: ", err)
        return nil, err
    end

    if resp.status ~= 200 then
        if resp.status ~= 404 then
            core.log.error("failed to fetch consumer from control plane, status: ", resp.status, ", body: ", core.json.delay_encode(resp.body, true))
            return nil, "failed to fetch consumer from control plane"
        else
            core.log.info("not found consumer, status: ", resp.status)
            return nil, "not found"
        end
    end

    local consumer, err = core.json.decode(resp.body)
    if not consumer then
        core.log.error("failed to decode consumer body: ", err)
        return nil, err
    end
    core.log.info("fetch consumer from agent: ", core.json.delay_encode(consumer))

    consumer.id = consumer.id or consumer.username
    consumer.consumer_name = consumer.consumer_name or consumer.username
    consumer.modifiedIndex = consumer.modifiedIndex or self.consumer_version
    self.consumer_version = self.consumer_version > MAX_CONF_VERSION and 0 or self.consumer_version + 1

    local ok, err = check_consumer(consumer)
    if not ok then
        core.log.error("failed to check the fetched consumer: ", err)
        return nil, err
    end

    if enable_gde() and consumer.auth_conf then
        plugin_decrypt_conf(query.plugin_name, consumer.auth_conf, core.schema.TYPE_CONSUMER)
    end

    return consumer
end


function _M.consumer_query(self, query)
    if type(query) ~= "table" then
        return nil, "consumer-query: \"query\" is not a table"
    end

    local cache_key = query.username or ( query.plugin_name .. "/" .. query.key_value)

    local miss = self.miss_consumer_cache(cache_key, nil, function () return nil end)
    if miss then
        return nil, "not found consumer"
    end

    local consumer, err = self.consumer_cache(cache_key, nil, fetch_consumer, self, self.consumer_query_url, query)
    if not consumer then
        if err == "not found" then
            self.miss_consumer_cache(cache_key, nil, function () return "not found consumer" end)
            return nil, "not found consumer"
        end
        return nil, err
    end
    return consumer
end


function _M.developer_query(self, query)
    if type(query) ~= "table" then
        return nil, "developer_query: \"query\" is not a table"
    end

    local cache_key = table.concat({
        query.plugin_name,
        query.key_value,
        query.service_id
    }, "/")

    core.log.debug("developer_query cache_key: ", cache_key)

    local miss = self.miss_developer_cache(cache_key, nil, function () return nil end)
    if miss then
        return nil, "not found developer"
    end

    local consumer, err = self.developer_cache(cache_key, nil, fetch_consumer, self, self.developer_query_url, query)
    if not consumer then
        if err == "not found" then
            self.miss_developer_cache(cache_key, nil, function () return "not found developer" end)
            return nil, "not found developer"
        end
        return nil, err
    end
    return consumer
end


function _M.new(agent_conf)
    local agent_name = agent_conf.name or "default"
    if agents[agent_name] then
        return agents[agent_name]
    end

    local init_api_calls, err = config_dict:get("api_calls_counter")
    if init_api_calls == nil then
        init_api_calls = 0
    end
    if err ~= nil then
        core.log.error("failed get api_calls_counter from dict, error: ", err)
        return nil
    end
    local http_timeout = 30 * 1000
    if agent_conf.http_timeout then
        http_timeout = tonumber(agent_conf.http_timeout:match("%d+")) * 1000
    end

    local self = {
        name = agent_name,
        consumer_query_url = agent_conf.endpoint .. "/api/dataplane/consumer_query",
        developer_query_url = agent_conf.endpoint .. "/api/dataplane/developer_query",
        heartbeat_url = agent_conf.endpoint .. "/api/dataplane/heartbeat",
        metrics_url = agent_conf.endpoint .. "/api/dataplane/metrics",
        healthcheck_url = agent_conf.endpoint .. "/api/dataplane/healthcheck",
        service_registry_healthcheck_url = agent_conf.endpoint .. "/api/dataplane/service_registry_healthcheck",
        ssl_cert_path = agent_conf.ssl_cert_path,
        ssl_key_path = agent_conf.ssl_key_path,
        ssl_ca_cert = agent_conf.ssl_ca_cert,
        ssl_verify = agent_conf.ssl_verify,
        ssl_server_name = agent_conf.ssl_server_name,
        heartbeat_interval = agent_conf.heartbeat_interval or 10,
        telemetry = agent_conf.telemetry,
        healthcheck_report_interval = agent_conf.healthcheck_report_interval,
        http_timeout = http_timeout,
        last_heartbeat_time = nil,
        ongoing_heartbeat = false,
        last_metrics_uploading_time = nil,
        ongoing_metrics_uploading = false,
        config_version = 0,
        consumer_config_version = 0,
        developer_config_version = 0,
        api_calls_counter_last_value = init_api_calls,
        consumer_version = 0,
        consumer_proxy = agent_conf.consumer_proxy,
        developer_proxy = agent_conf.developer_proxy,
        run_id = agent_conf.run_id,
    }
    core.log.info("new agent created: ", core.json.delay_encode(self, true))

    local agent = setmetatable(self, mt)
    agent:set_consumer_cache(agent_conf.consumer_proxy)
    agent:set_developer_cache(agent_conf.developer_proxy)

    agents[agent_name] = agent
    return agent
end


function _M.set_consumer_cache(self, conf)
    conf = conf or {}

    self.miss_consumer_cache = core.lrucache.new({
        ttl = conf.cache_failure_ttl or 60, -- unit: second
        count = conf.cache_failure_count or 512,
        invalid_stale = true
    })
    self.consumer_cache = core.lrucache.new({
        ttl = conf.cache_success_ttl or 60, -- unit: second
        count = conf.cache_success_count or 512,
        invalid_stale = true
    })
end


function _M.set_developer_cache(self, conf)
    conf = conf or {}

    self.miss_developer_cache = core.lrucache.new({
        ttl = conf.cache_failure_ttl or 15, -- unit: second
        count = conf.cache_failure_count or 256,
        invalid_stale = true
    })
    self.developer_cache = core.lrucache.new({
        ttl = conf.cache_success_ttl or 15, -- unit: second
        count = conf.cache_success_count or 256,
        invalid_stale = true
    })
end


function _M.get_agent(name)
    return agents[name]
end

return _M
