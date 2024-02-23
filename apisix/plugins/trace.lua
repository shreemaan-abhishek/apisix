local require = require
local apisix = require("apisix")
local core = require("apisix.core")

local ngx = ngx
local tostring = tostring
local format = string.format
local floor = math.floor

local old_http_access_phase
local old_match_route
local old_http_log_phase
local old_http_balancer_phase
local old_http_header_filter_phase
local old_http_body_filter_phase

local schema = {}

local suffix = [[
+----------+---------------------------+----------+-------------------------+
]]
local prefix = [[

+----------+---------------------------+----------+-------------------------+
| Role     | Phase                     | Timespan | Start time              |
]] .. suffix

local plugin_name = "trace"

local _M = {
    version = 0.1,
    priority = 22901,
    name = plugin_name,
    schema = schema,
    scope = "global",
}

local function nspaces(n)
  return (" "):rep(n)
end

local function add_entry(phase, timespan, curtime)
  core.log.info("add entry for: ", phase)
  local role
  local tpl = [[
| %s| %s| %s| %s |
]]
  if phase == "upstream (req + response)" then
    role = "Upstream "
  elseif  phase == "response" then
    role = "Client   "
  else
    role = "APISIX   "
  end

  -- add spaces around the text for table formatting
  phase = phase .. nspaces(26 - #phase)
  timespan = timespan .. nspaces(9 - #tostring(timespan))
  ngx.ctx.trace = ngx.ctx.trace .. format(tpl, role, phase, timespan, curtime)
end


local function timespan(raw)
  local unit = 1000 -- 1000ms in 1s
  if raw >= 1 then -- if greater than 1s don't convert to ms
    unit = 1
  end
  return floor(raw * unit + 0.5) .. "ms"
end


local function localtime_msec(now)
  local lt = ngx.localtime()
  local msec =  now * 1000 - floor(now) * 1000
  if msec > 0 then
    return lt .. "." .. msec
  end
  return lt .. ".000"
end


function _M.init()

  local conf = core.config.local_conf()
  local router_name = "radixtree_uri"
  if conf and conf.apisix and conf.apisix.router then
    router_name = conf.apisix.router.http or router_name
  end

  local router = require("apisix.http.router." .. router_name)
  old_match_route = router.match
  router.match = function (...)
    local match_start = ngx.now()
    ngx.ctx.match_lt = localtime_msec(match_start)

    old_match_route(...)
    ngx.update_time()

    ngx.ctx.match_timespan = timespan(ngx.now() - match_start)
  end

  old_http_access_phase = apisix.http_access_phase
  apisix.http_access_phase = function (...)
    ngx.ctx.trace = prefix

    local access_start = ngx.now()
    ngx.ctx.access_lt = localtime_msec(access_start)

    old_http_access_phase(...)
    ngx.update_time()

    ngx.ctx.access_timespan = timespan(ngx.now() - access_start)
  end

  old_http_balancer_phase = apisix.http_balancer_phase
  apisix.http_balancer_phase = function (...)
    local balancer_start = ngx.now()
    ngx.ctx.balancer_lt = localtime_msec(balancer_start)

    old_http_balancer_phase(...)
    ngx.update_time()

    ngx.ctx.balancer_timespan = timespan(ngx.now() - balancer_start)
    ngx.update_time()
    ngx.ctx.upstream_start = ngx.now()
    ngx.ctx.upstream_lt = localtime_msec(ngx.ctx.upstream_start)
  end

  old_http_header_filter_phase = apisix.http_header_filter_phase
  apisix.http_header_filter_phase = function (...)
    local header_filter_start = ngx.now()
    ngx.ctx.upstream_end = header_filter_start
    ngx.ctx.header_filter_start = localtime_msec(header_filter_start)

    old_http_header_filter_phase(...)
    ngx.update_time()

    ngx.ctx.header_filter_timespan = timespan(ngx.now() - header_filter_start)
  end

  old_http_body_filter_phase = apisix.http_body_filter_phase
  apisix.http_body_filter_phase = function (...)
    local body_filter_start = ngx.now()
    if not ngx.ctx.bf_timespan then
      ngx.ctx.bf_timespan = 0
      ngx.ctx.bf_lt = localtime_msec(body_filter_start)
    end

    old_http_body_filter_phase(...)
    ngx.update_time()

    ngx.ctx.bf_end = ngx.now()
    ngx.ctx.bf_timespan = ngx.ctx.bf_timespan + (ngx.ctx.bf_end - body_filter_start)
    ngx.ctx.response_lt = localtime_msec(ngx.ctx.bf_end)
  end

  old_http_log_phase = apisix.http_log_phase
  apisix.http_log_phase = function (...)
    local log_start = ngx.now()
    local log_lt = localtime_msec(log_start)

    old_http_log_phase(...)
    ngx.update_time()
    local log_end = ngx.now()

    local premature = false
    -- when route match fails access_timespan = nil
    if not ngx.ctx.access_timespan then
      ngx.ctx.access_timespan = "0ms"
      premature = true
    end
    add_entry("access", ngx.ctx.access_timespan, ngx.ctx.access_lt)
    add_entry("\\_match_route", ngx.ctx.match_timespan, ngx.ctx.match_lt)
    if not premature then
      add_entry("balancer", ngx.ctx.balancer_timespan, ngx.ctx.balancer_lt)
      add_entry("upstream (req + response)",
        timespan(ngx.ctx.upstream_end - ngx.ctx.upstream_start),
        ngx.ctx.upstream_lt)
    end
    add_entry("header_filter", ngx.ctx.header_filter_timespan, ngx.ctx.header_filter_start)
    add_entry("body_filter", timespan(ngx.ctx.bf_timespan), ngx.ctx.bf_lt)
    if not premature then
      add_entry("response", timespan(log_start - ngx.ctx.bf_end), ngx.ctx.response_lt)
    end
    add_entry("log", timespan(log_end - log_start), log_lt)
    core.log.warn("trace: ", ngx.ctx.trace .. suffix)
    ngx.ctx.trace = "" -- clear trace
    ngx.ctx.bf_timespan = nil -- clear body_filter timespan
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
  apisix.http_balancer_phase = old_http_balancer_phase
  apisix.http_header_filter_phase = old_http_header_filter_phase
  apisix.http_body_filter_phase = old_http_body_filter_phase
  apisix.http_log_phase = old_http_log_phase
end

return _M
