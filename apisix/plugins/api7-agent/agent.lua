local core    = require("apisix.core")
local socket  = require("socket")
local http    = require("resty.http")
local utils   = require("apisix.plugins.api7-agent.utils")

local setmetatable  = setmetatable
local ngx_time      = ngx.time
local str_format    = string.format

local _M = {}

local mt = {
    __index = _M
}

local payload = {
    instance_id = core.id.get(),
    hostname = core.utils.gethostname(),
    ip = socket.dns.toip(core.utils.gethostname()),
    version = core.version.VERSION,
    ports = utils.get_listen_ports(),
}

local headers = {
    ["Content-Type"] = "application/json",
}


function _M.heartbeat(self)
    local current_time = ngx_time()
    if self.last_heartbeat_time and
            current_time - self.last_heartbeat_time < self.heartbeat_interval then
        return
    end

    payload.conf_server_revision = utils.get_conf_server_revision()

    payload["gateway_group_id"] = self.gateway_group_id
    payload.cores = ngx.worker.count()
    local post_heartbeat_payload = core.json.encode(payload)

    local http_cli = http.new()

    http_cli:set_timeout(3 * 1000)

    local res, err = http_cli:request_uri(self.heartbeat_url, {
        method =  "POST",
        body = post_heartbeat_payload,
        headers = headers,
        keepalive = true,
        ssl_verify = false,
        ssl_cert_path = self.ssl_cert_path,
        ssl_key_path = self.ssl_key_path,
    })

    if not res then
        core.log.error("heartbeat failed ", err)
        return
    end

    self.last_heartbeat_time = current_time

    if res.status ~= 200 then
        core.log.warn("heartbeat failed, status: " .. res.status .. ", body: ", res.body)
        return
    end

    local msg = str_format("gateway_group \'%s\', dp instance \'%s\' heartbeat successfully",
                           payload.gateway_group_id, payload.instance_id)
    core.log.info(msg)
end


function _M.upload_metrics(self)
    local current_time = ngx_time()
    if self.last_metrics_uploading_time and
            current_time - self.last_metrics_uploading_time < self.telemetry_collect_interval then
        return
    end

    local payload = {
        instance_id = core.id.get(),
        gateway_group_id = self.gateway_group_id,
    }

    -- Since we should get the metrics of nginx status,
    -- and we can't start sub-request in timer,
    -- so we should send request to APISIX metrics port.
    local res, err = utils.fetch_metrics()
    if err then
        core.log.error("fetch prometheus metrics error ", err)
        return
    end
    if res.status ~= 200 then
        core.log.error("failed to fetch prometheus metrics, status: ", res.status)
        return
    end

    local metrics = res.body

    if #metrics > self.max_metrics_size then
        core.log.warn("metrics size is too large, truncating it, size: ", #metrics, ", after truncated: ", self.max_metrics_size)
        payload.truncated = true
        metrics = string.sub(metrics, 1, self.max_metrics_size)
    end

    payload.metrics = metrics

    local http_cli = http.new()

    http_cli:set_timeout(3 * 1000)

    local res, err = http_cli:request_uri(self.metrics_url, {
        method =  "POST",
        body = core.json.encode(payload),
        headers = headers,
        keepalive = true,
        ssl_verify = false,
        ssl_cert_path = self.ssl_cert_path,
        ssl_key_path = self.ssl_key_path,
    })

    local resp_body
    if not res then
        core.log.error("upload metrics failed ", err)
        return
    end

    self.last_metrics_uploading_time = current_time

    if res.status ~= 200 then
        core.log.warn("upload metrics failed, status: " .. res.status .. ", body: ", res.body)
        return
    end

    local msg = str_format("gateway_group \'%s\', dp instance \'%s\' upload metrics to control plane successfully",
                           payload.gateway_group_id, payload.instance_id)
    core.log.info(msg)
end


function _M.new(agent_conf)
    local self = {
        gateway_group_id = agent_conf.gateway_group_id,
        heartbeat_url = agent_conf.endpoint .. "/api/dataplane/heartbeat",
        metrics_url = agent_conf.endpoint .. "/api/dataplane/metrics",
        ssl_cert_path = agent_conf.ssl_cert_path,
        ssl_key_path = agent_conf.ssl_key_path,
        heartbeat_interval = 10,
        telemetry_collect_interval = 15,
        max_metrics_size = agent_conf.max_metrics_size,
        last_heartbeat_time = nil,
        last_metrics_uploading_time = nil,
    }

    return setmetatable(self, mt)
end


return _M

