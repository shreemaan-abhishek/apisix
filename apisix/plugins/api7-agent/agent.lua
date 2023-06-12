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
    local first_heartbeat = not self.last_heartbeat_time

    local current_time = ngx_time()
    if self.last_heartbeat_time and
            current_time - self.last_heartbeat_time < self.heartbeat_interval then
        return
    end

    payload.conf_server_revision = utils.get_conf_server_revision()
    local post_heartbeat_payload = core.json.encode(payload)

    local http_cli = http.new()

    http_cli:set_timeout(3 * 1000)

    local res, err = http_cli:request_uri(self.heartbeat_url, {
        method =  "POST",
        body = post_heartbeat_payload,
        headers = headers,
        keepalive = true,
        ssl_verify = false,
    })

    local resp_body
    if not res then
        core.log.error("heartbeat failed ", err)
        return
    end

    self.last_heartbeat_time = current_time

    if res.status ~= 200 then
        core.log.warn("heartbeat failed, status: " .. res.status .. ", body: ", res.body)
        return
    end

    local msg = str_format("dp instance \'%s\' heartbeat successfully", payload.instance_id)
    core.log.info(msg)
end


function _M.new(agent_conf)
    local self = {
        heartbeat_url = agent_conf.endpoint .. "/dataplane/heartbeat",
        metrics_url = agent_conf.endpoint .. "/dataplane/metrics",
        heartbeat_interval = 10,
        last_heartbeat_time = nil,
    }

    return setmetatable(self, mt)
end


return _M

