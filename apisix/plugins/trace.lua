local require = require
local apisix = require("apisix")
local core = require("apisix.core")
local ngx = ngx
local old_http_access_phase
local old_match_route
local old_http_log_phase

local schema = {}

local plugin_name = "trace"

local _M = {
    version = 0.1,
    priority = 22901,
    name = plugin_name,
    schema = schema,
    scope = "global",
}

function _M.init()

  local conf = core.config.local_conf()
  local router_name = "radixtree_uri"
  if conf and conf.apisix and conf.apisix.router then
    router_name = conf.apisix.router.http or router_name
  end

  local router = require("apisix.http.router." .. router_name)
  old_match_route = router.match
  router.match = function (...)
    ngx.ctx.traces.match_route_start = ngx.now()
    old_match_route(...)
    ngx.update_time()
    ngx.ctx.timespan.match_route = ngx.now() - ngx.ctx.traces.match_route_start
  end

  old_http_access_phase = apisix.http_access_phase
  apisix.http_access_phase = function (...)
    ngx.ctx.traces = {}
    ngx.ctx.timespan = {}
    ngx.ctx.traces.http_access_start = ngx.now()
    old_http_access_phase(...)
    ngx.update_time()
    ngx.ctx.timespan.http_access_phase = ngx.now() - ngx.ctx.traces.http_access_start
  end

  old_http_log_phase = apisix.http_log_phase
  apisix.http_log_phase = function (...)
    ngx.ctx.traces.http_log_start = ngx.now()
    old_http_log_phase(...)
    ngx.ctx.timespan.http_log_phase = ngx.now() - ngx.ctx.traces.http_log_start
    core.log.info("trace: ", core.json.delay_encode(ngx.ctx.timespan))
  end
end

function _M.destroy()
  local conf = core.config.local_conf()
  local router_name = "radixtree_uri"
  if conf and conf.apisix and conf.apisix.router then
    router_name = conf.apisix.router.http or router_name
  end

  local router = require("apisix.http.router." .. router_name)
  router.match = old_match_route

  apisix.http_access_phase = old_http_access_phase
  apisix.http_log_phase = old_http_log_phase
end

return _M
