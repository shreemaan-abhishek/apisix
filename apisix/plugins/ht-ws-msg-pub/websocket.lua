local require = require
local pairs = pairs
local setmetatable = setmetatable
local semaphore = require("ngx.semaphore")
local ws_server = require("resty.websocket.server")
local core = require("apisix.core")
local misc_utils = require("apisix.utils.misc")
local decoder = require("apisix.plugins.ht-ws-msg-pub.decoder")

local _M = { version = 0.1 }
local mt = { __index = _M }


do
    local ws_connections = {}
    function _M.get_ws_connection(id)
        core.log.info("get ws connection, id: ", id)
        core.log.info("ws_connections: ", core.json.delay_encode(ws_connections, true))

        if not id then
           return nil, "id is required"
        end

        return ws_connections[id]
    end


    ---
    -- Apply ws connection
    --
    function _M.apply_ws_connection()
        local ws, err = ws_server:new()
        if not ws then
            return nil, err
        end

        local sema, err = semaphore.new()
        if not sema then
            return nil, err
        end

        local obj = setmetatable({
            id = misc_utils.get_sid(),
            ws = ws,
            decoder = decoder,
            queue = {},
            sema = sema,
            pong = function (req)
                req.uri = "/api/pong"
                return req
            end,
            handler = function (req)
                return false, nil, nil
            end,
        }, mt)

        ws_connections[obj.id] = obj

        return obj
    end


    function _M.release_ws_connection(connection)
        local id = connection.id
        if not id then
            return
        end

        ws_connections[id] = nil
    end


    function _M.count_connections()
        return core.table.nkeys(ws_connections)
    end


    function _M.get_queue_size()
        local count = 0
        for _, conn in pairs(ws_connections) do
            count = count + #conn.queue
        end

        return count
    end

end -- do


return _M
