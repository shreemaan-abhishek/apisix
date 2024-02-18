local ngx = ngx
local require = require
local ngx_worker_id = ngx.worker.id
local socket  = require("socket")
local core    = require("apisix.core")

local _M = {}


local server_ip
local function get_server_ip()
    if server_ip then
        return server_ip
    end

    server_ip = socket.dns.toip(core.utils.gethostname())

    return server_ip or ngx.var.server_addr
end
_M.get_server_ip = get_server_ip


local worker_id
local function get_worker_id()
    if worker_id then
        return worker_id
    end

    worker_id = ngx_worker_id()

    return worker_id
end
_M.get_worker_id = get_worker_id


local worker_uni
local function get_worker_uni_id()
    if worker_uni then
        return worker_uni
    end

    local server_ip = get_server_ip()
    local worker_id = ngx_worker_id()

    worker_uni = server_ip .. "_" .. worker_id

    return worker_uni
end
_M.get_worker_uni_id = get_worker_uni_id


local idx = 0
function _M.get_sid()
    idx = idx + 1
    if idx > 2^30 then
        idx = 1
    end

    local worker_uni_id = get_worker_uni_id()

    return worker_uni_id .. '_' .. idx
end


return _M
