local require = require
local table_remove = table.remove
local ipairs = ipairs
local ngx = ngx
local ngx_now = ngx.now
local exiting = ngx.worker.exiting
local re_gsub = ngx.re.gsub
local core = require("apisix.core")
local topic = require("apisix.utils.topic")
local log = require("apisix.plugins.ht-ws-msg-pub.log")
local metrics = require("apisix.plugins.ht-ws-msg-pub.metrics")
local push_gateway = require("apisix.plugins.ht-ws-msg-pub.push_gateway")

local _M = {}


-- Send a response to the client
local function send_resp(ws, typ, data)
    if typ == "text" then
        return ws:send_text(data)
    end

    if typ == "binary" then
        return ws:send_binary(data)
    end

    if typ == "ping" then
        return ws:send_pong(data)
    end

    if typ == "close" then
        return ws:send_close(1000, data)
    end

    return 0, "unknown websocket frame type: " .. typ
end


local function report_close(conf, ws_connection)
    if ws_connection.closed or not conf.disconnect_notify_urls then
        return
    end

    core.log.info("report client closing info to: ",
        core.json.delay_encode(conf.disconnect_notify_urls))
    ws_connection.closed = true
    local nowtime = ngx_now()
    for _, url in ipairs(conf.disconnect_notify_urls) do
        local req = {
            uri = url,
            header = {
                msgId = "" .. nowtime,
                ts = nowtime,
                appId = "1",
                ["Content-Type"] = "application/json",
            }
        }
        local _, resp = ws_connection.handler(req)
        if resp and resp.status ~= 200 then
            core.log.warn("failed to report client closing info to: ", url,
                ", status: ", resp.status)
        end
    end
end


local function disconnect(conf, ws_connection)
    local subcribed = topic.get_topics_by_sid(ws_connection.id)
    core.log.info("disconnect sid: ", ws_connection.id,
        ", subcribed topics: ", core.json.delay_encode(subcribed))

    local subcribed_topics = subcribed and core.table.clone(subcribed)
    topic.disconnect(ws_connection.id, subcribed)

    local removed_topics = topic.get_removed_topics(subcribed_topics)
    core.log.info("disconnect sid: ", ws_connection.id,
        ", should be removed topics: ", core.json.delay_encode(removed_topics))

    -- check and sync delete topic to push gateway
    if removed_topics and #removed_topics > 0 then
        local paction = "sub_delete"
        local msgId = ws_connection.id .. ngx_now()
        push_gateway.notify(paction, msgId, removed_topics)
    end

    report_close(conf, ws_connection)
end


local function set_metrics(route_id, subroute_id, status, latency)
    metrics.incr_status(route_id, subroute_id, status)
    metrics.observe_latency(route_id, subroute_id, latency)
end


function _M.from_downstream_thread(ctx, conf, ws_connection)
    local fatal_err
    while not exiting() do
        local _req_start = ngx_now()
        -- read req data frames from websocket connection
        local req_data, req_type, err = ws_connection.ws:recv_frame()
        if err then
            -- terminate the event loop when a fatal error occurs
            if ws_connection.ws.fatal then
                fatal_err = err
                break
            end

            -- handle client close connection
            if req_type == "close" then
                ws_connection.ws:send_close(1000, [[{"message": "connection closed by server"}]])
                break
            end

            -- skip this loop for non-fatal errors
            core.log.info("failed to receive websocket frame: ", err)
            goto CONTINUE
        end

        -- handle client close connection
        if req_type == "close" then
            ws_connection.ws:send_close(1000, [[{"message": "connection closed by server"}]])
            break
        end

        local req, err = ws_connection.decoder.decode(req_data)
        if err then
            local err = "failed to decode websocket frame, err: " .. err
            core.log.warn(err, ", req_data: ", req_data, ", req_type: ", req_type)
            send_resp(ws_connection.ws, req_type,
                ws_connection.decoder.encode_error(400, "", "", err))
            local latency = ngx_now() - _req_start
            set_metrics(ctx.matched_route.value.id, "", 400, latency)
            goto CONTINUE
        end

        local need_to_respond, resp
        if req_type == "ping" or req.uri == "/api/ping" then
            need_to_respond = true
            resp = ws_connection.pong(req)
        else
            core.log.info("req uri: ", req.uri, " conf.disconnect_notify_urls:",
                core.json.delay_encode(conf.disconnect_notify_urls),
                " find res:", core.table.array_find(conf.disconnect_notify_urls, req.uri)
            )
            if core.table.array_find(conf.disconnect_notify_urls, req.uri) then
                ws_connection.closed = true
            end

            need_to_respond, resp, err = ws_connection.handler(req)
        end

        local subroute_id = resp.subroute and resp.subroute.value.id or ""

        local msg_id = req.header and req.header.msgId or ""
        if err then
            core.log.error("failed to process: ", " err: ", err)
            send_resp(ws_connection.ws, req_type,
                ws_connection.decoder.encode_error(500, msg_id, "5001", err))
            local latency = ngx_now() - _req_start
            set_metrics(ctx.matched_route.value.id, subroute_id, 500, latency)
            goto CONTINUE
        end

        -- if not send response to client, skip this loop
        if not need_to_respond then
            goto CONTINUE
        end

        -- remove subroute from response
        if resp.subroute then
            resp.subroute = nil
        end

        local resp_data, err = ws_connection.decoder.encode(resp)
        if not resp_data then
            core.log.error("failed to encode response: ", err)
            send_resp(ws_connection.ws, req_type,
                ws_connection.decoder.encode_error(500, msg_id, "5002", err))
            local latency = ngx_now() - _req_start
            set_metrics(ctx.matched_route.value.id, subroute_id, 500, latency)
            goto CONTINUE
        end

        -- close the connection when the client is not authorized
        local resp_type = req_type
        if resp.status == 401 then
            resp_type = "close"
        end

       local _, err = send_resp(ws_connection.ws, resp_type, resp_data)
        if err then
            -- terminate the event loop when a fatal error occurs
            if ws_connection.ws.fatal then
                fatal_err = err
                break
            end

            core.log.error("failed to send response: ", err)
        end

        -- pong does not need to record metrics
        if resp.status then
            local latency = ngx_now() - _req_start
            set_metrics(ctx.matched_route.value.id, subroute_id, resp.status, latency)
        end

        ::CONTINUE::
    end

    if fatal_err then
        core.log.warn("fatal error in websocket server, err: ", fatal_err)
    end

    disconnect(conf, ws_connection)
end


local function gen_push_log(log_message, sid, status, ts)
    if ts then
        return log_message .. ',"sid":"' .. sid .. '","status":' ..
            status .. ',"apisix_ts":' .. ts .. '}'
    end

    return log_message .. ',"sid":"' .. sid .. '","status":' .. status .. '}'
end


function _M.to_downstream_thread(ctx, conf, ws_connection)
    while not exiting() do
        local ok, err = ws_connection.sema:wait(60)
        if not ok then
            if err and err ~= "timeout" then
                core.log.error("failed to wait semaphore : ", err)
                ws_connection.ws:send_close(1000, [[{"message": "connection closed by server"}]])
                break
            end

            core.log.info("to_downstream_thread wait timeout with no data to send")
            goto CONTINUE
        end

        if #ws_connection.queue == 0 then
            goto CONTINUE
        end

        local queue_item = table_remove(ws_connection.queue, 1)
        if not queue_item or not queue_item.data then
            goto CONTINUE
        end

        local ts
        if conf.apisix_ts_disabled then
            queue_item.data = re_gsub(queue_item.data, [[,"apisix_ts":"@apisix_ts_val@"]], "", "jo")
        else
            ts =  ngx_now() * 1000
            queue_item.data = re_gsub(queue_item.data, [["@apisix_ts_val@"]], ts, "jo")
        end

        local _, err = ws_connection.ws:send_text(queue_item.data)

        local log_message = gen_push_log(queue_item.log_message,
            ws_connection.id, err and 505 or 200, ts)
        log.push_log(log_message)

        core.log.info("send websocket client msg: ", queue_item.data, " to: ", ws_connection.id)
        if err then
            core.log.error("failed to send response: ", err)
            -- terminate the event loop when a fatal error occurs
            if ws_connection.ws.fatal then
                break
            end
        end

        metrics.incr_pub_total(queue_item.topic)

        ::CONTINUE::
    end

    disconnect(conf, ws_connection)
end


return _M
