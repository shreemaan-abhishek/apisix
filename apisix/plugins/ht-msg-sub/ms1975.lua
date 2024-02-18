local require = require
local str_byte = string.byte
local ngx = ngx
local setmetatable = setmetatable
local ngx_socket_tcp = ngx.socket.tcp
local bit = require("bit")
local lshift = bit.lshift
local core = require("apisix.core")
local load_balancer = require("apisix.balancer")
local decoder = require("apisix.plugins.ht-msg-sub.ms1975_decoder")

local MAGIC_LENGTH = 2
local BODY_LEN_LENGTH = 4

local _M = {}
local mt = { __index = _M }


local function hex2int(hex)
    local len0 = str_byte(hex,1)
    local len1 = str_byte(hex,2)
    local len2 = str_byte(hex,3)
    local len3 = str_byte(hex,4)

    return len0 + lshift(len1, 8) + lshift(len2, 16) + lshift(len3, 24)
end


function _M.new(self)
    local sock, err = ngx_socket_tcp()
    if not sock then
        return nil, err
    end

    return setmetatable({
        _sock = sock,
    }, mt)
end


function _M.connect_upstream(self, ctx, node)
    local ok, err = self._sock:connect(node.host, node.port)
    if not ok then
        core.log.error("failed to connect: ", err, " host: ", node.host, " port: ", node.port)
        return false, err
    end

    if ctx.upstream_conf.scheme == "tls" then
        -- TODO: support mTLS
        local ok, err = self._sock:sslhandshake(nil, node.host)
        if not ok then
            core.log.error("failed to handshake: ", err, " host: ", node.host)
            return false, err
        end
    end

    return true
end


function _M.retry_connect(self, ctx)
    local retries = ctx.upstream_conf.retries
        and ctx.upstream_conf.retries or #ctx.upstream_conf.nodes

    local ok, err = false, nil
    for i = 1, retries do
        local node
        node, err = load_balancer.pick_server(ctx.matched_route, ctx)
        if not node then
            core.log.error("failed to pick server, node: ",
                core.json.delay_encode(node, true), " error:", err)
            goto CONTINUE
        end

        ok, err = self:connect_upstream(ctx, node)
        if not ok then
            core.log.error("failed to connect to upstream, node: ",
                core.json.delay_encode(node, true), " error:", err)
            goto CONTINUE
        end

        break

        ::CONTINUE::
    end

    return ok, err
end


function _M.connect(self, ctx)
    local node, err = load_balancer.pick_server(ctx.matched_route, ctx)
    if not node then
        core.log.error("failed to pick server node: ", err)
        return false, err
    end

    local timeout = ctx.upstream_conf.timeout
    if not timeout then
        -- use the default timeout of Nginx proxy
        self._sock:settimeouts(60 * 1000, 60 * 1000, 60 * 1000)
    else
        -- the timeout unit for balancer is second while the unit for cosocket is millisecond
        self._sock:settimeouts(timeout.connect * 1000, timeout.send * 1000, timeout.read * 1000)
    end

    local ok, err = self:connect_upstream(ctx, node)
    if not ok then
        core.log.error("failed to connect to upstream: ", err)
        return false, err
    end

    return true
end


function _M.setkeepalive(self, keepalive_timeout, keepalive_size)
    local ok, err = self._sock:setkeepalive(keepalive_timeout * 1000, keepalive_size)
    if not ok then
        core.log.error("failed to set reusable: ", err)
    end
end


function _M.close(self)
    self._sock:close()
end


local function read_data(sk, len)
    local p, err = sk:receive(len)
    if not p then
        return nil, err
    end

    return p
end


function _M.to_upstream(self, uri, header, body)
    -- encode request data
    local req_data, err = decoder.encode(uri, header, body)
    if not req_data then
        core.log.error("failed to encode req data: ", err)
        return nil, err
    end

    -- send data to upstream
    local bytes, err = self._sock:send(req_data)
    if not bytes then
        core.log.error("failed to send data to upstream: ", err)
        return nil, err
    end

    -- receive data from upstream
    local magic, err = read_data(self._sock, MAGIC_LENGTH)
    if magic == nil then
        core.log.error("read data error: ", err)
        return nil, err
    end

    -- get body length
    local body_len, err = read_data(self._sock, BODY_LEN_LENGTH)
    if body_len == nil then
        core.log.error("read body length error: ", err)
        return nil, err
    end

    -- read body
    local body, err = read_data(self._sock, hex2int(body_len))
    if body == nil then
        core.log.error("read body error: ", err)
        return nil, err
    end

    -- decode data to table
    local resp, err = decoder.decode(magic .. body_len .. body)
    if not resp then
        core.log.error("failed to decode resp data: ", err)
        return nil, err
    end

    return resp
end


return _M
