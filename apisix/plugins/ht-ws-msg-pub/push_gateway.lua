local require = require
local pairs = pairs
local ipairs  = ipairs
local ngx = ngx
local table_remove = table.remove
local pairs = pairs
local string = string
local math_random = math.random
local ngx_md5 = ngx.md5
local timer_at = ngx.timer.at
local ngx_time = ngx.time
local exiting = ngx.worker.exiting
local wait = ngx.thread.wait
local thread_spawn = ngx.thread.spawn
local thread_kill = ngx.thread.kill
local semaphore = require("ngx.semaphore")
local ws_client = require("resty.websocket.client")
local core   = require("apisix.core")
local plugin = require("apisix.plugin")
local topic = require("apisix.utils.topic")
local queue = require("apisix.utils.queue")
local misc_utils = require("apisix.utils.misc")
local pkg_prefix = "apisix.plugins.ht-ws-msg-pub."
local decoder = require(pkg_prefix .. "decoder")
local log = require(pkg_prefix .. "log")
local metrics = require(pkg_prefix .. "metrics")
local websocket = require(pkg_prefix .. "websocket")

local _M = {}


-- new a timer
local function new_timer(callback_fun, addr)
    local timer = {
        addr  = addr,
        queue = {},
        sema  = semaphore.new(),
        diffing = false,
        diffing_queue = {},
    }

    local hdl, err = timer_at(0, callback_fun, timer)
    if not hdl then
        return nil, err
    end

    return timer
end


local push_gateway_timers = {}
local function apply_timer(callback_fun, addr)
    if push_gateway_timers[addr] then
        return push_gateway_timers[addr]
    end

    push_gateway_timers[addr] = new_timer(callback_fun, addr)

    return push_gateway_timers[addr]
end


local function release_timer(timer, close_ws_cli)
    if not timer or timer.exiting then
        return
    end

    if timer.ws_cli and close_ws_cli then
        timer.ws_cli:close()
        timer.ws_cli = nil
    end

    timer.exiting = true
    push_gateway_timers[timer.addr] = nil
end


-- return addrs that not in push_gateway_timers,
-- and push_gateway_timers that not in addrs
local function addrs_diff(addrs)
    local new_addrs = {}
    local useless_timers = {}

    for _, addr in ipairs(addrs) do
        core.log.info("addr: ", addr, " push_gateway_timers: ",
            core.json.delay_encode(push_gateway_timers, true),
            " not existed:", (not push_gateway_timers[addr])
        )
        if not push_gateway_timers[addr] then
            core.table.insert(new_addrs, addr)
        end
    end

    for addr, _ in pairs(push_gateway_timers) do
        core.log.info("addr: ", addr, " addrs: ", core.json.delay_encode(addrs))
        if not core.table.array_find(addrs, addr) then
            core.table.insert(useless_timers, addr)
        end
    end

    return new_addrs, useless_timers
end


local function from_push_gateway_thread(timer)
    local fatal_err
    while not exiting() and not timer.exiting do
        -- read raw data frames from websocket connection
        local raw_data, raw_type, err = timer.ws_cli:recv_frame()
        core.log.info("receive raw data: ", core.json.delay_encode(raw_data))
        if err then
            -- terminate the event loop when a fatal error occurs
            if timer.ws_cli.fatal then
                fatal_err = err

                break
            end

            if not string.find(err, "timeout") then
                core.log.error("failed to receive websocket frame: ", err)
                break
            end

            goto CONTINUE
        end

        -- handle client close connection
        if raw_type == "close" then
            fatal_err = "received close frame from push gateway"
            break
        end

        if raw_type == "pong" then
            core.log.info("received pong frame from push gateway")
            goto CONTINUE
        end

        local msg, err = decoder.decode(raw_data)
        if not msg then
            core.log.error("failed to decode websocket frame, err: " .. err,
                ", raw_data: ", core.json.delay_encode(raw_data))

            goto CONTINUE
        end

        if msg.action == "topics_diff" then
            core.log.info("received topics diff response frame from push gateway",
                core.json.delay_encode(msg))

            if msg.diff then
                local all_topics = topic.get_all_topics()
                _M.notify("sub_put", ngx_time() .. "", all_topics)
            end

            goto CONTINUE
        end

        if msg.action ~= "pub_msg" then
            core.log.info("received non-push frame from push gateway")
            goto CONTINUE
        end

        if not msg.body or not msg.body.topic then
            core.log.error("invalid msg, raw data: ", raw_data)
            goto CONTINUE
        end

        local tp = msg.body.topic
        local body = msg.body
        body.code = "0"
        body.apisix_ts = "@apisix_ts_val@"
        local data_to_push = core.json.encode({
            status = 200,
            body = body
        })
        local queue_item = {
            topic = tp,
            data = data_to_push,
            log_message = '{"body":{"msgId":"' .. body.msgId  .. '"}'
        }

        local sid_list = topic.get_sids_by_topic(tp)
        if not sid_list or #sid_list == 0 then
            core.log.info("no sid found for topic: ", tp)
            goto CONTINUE
        end

        log.push_log(data_to_push)
        metrics.incr_received_push_total()

        for _, sid in ipairs(sid_list) do
            local ws_connection = websocket.get_ws_connection(sid)
            if not ws_connection then
                core.log.error("failed to get ws connection by sid: ", sid)
                goto CONTINUE2
            end

            queue.push(ws_connection.queue, queue_item)
            ws_connection.sema:post(1)

            ::CONTINUE2::
        end

        ::CONTINUE::
    end

    core.log.warn("from push gateway thread exit: ", fatal_err, ", addr: ", timer.addr)

    release_timer(timer, true)
end


local function to_push_gateway_thread(timer)
    local attr = plugin.plugin_attr("ht-ws-msg-pub")
    local interval = attr and attr.heartbeat_interval or 60
    core.log.info("heartbeat interval: ", interval)

    while not exiting() and not timer.exiting do
        local ok, err = timer.sema:wait(interval)
        if not ok then
            if err ~= "timeout" then
                core.log.warn("failed to wait sema: ", err)
                break
            end

            -- check if the timer is exiting
            if timer.exiting then
                break
            end

            core.log.info("timeout to wait data, trigger heartbeat, addr: ", timer.addr)
            -- if timeout, send ping to all connections
            queue.push(timer.queue, {action="heartbeat", msgid=ngx_time()})
        end

        core.log.info("queue size: ", #timer.queue)

        if #timer.queue == 0 then
            goto CONTINUE
        end

        local data = table_remove(timer.queue, 1)
        if not data then
            goto CONTINUE
        end

        local bytes, err
        local msg = core.json.encode(data)
        if data.action == "heartbeat" then
            bytes, err = timer.ws_cli:send_ping(msg)
        else
            bytes, err = timer.ws_cli:send_text(msg)
        end

        if not bytes then
            if timer.ws_cli.fatal then
                release_timer(timer, true)
                core.log.error("failed to send msg length: ", #msg,
                    " err:", err, " addr: ", timer.addr)
                break
            end

            core.log.error("failed to send msg: ", msg, " err:", err, " addr: ", timer.addr)
        end

        core.log.info("send msg: ", msg, " addr: ", timer.addr, " byte sent: ", bytes)

        ::CONTINUE::
    end

    core.log.error("to push gateway thread exit, addr: ", timer.addr)

    release_timer(timer, true)
end


local function push_gateway_handler(premature, timer)
    if premature then
        return
    end

    local ws_cli = ws_client:new({
        timeout = 5000,
        max_payload_len = 6400000,
    })
    local ok, err = ws_cli:connect(timer.addr)
    if not ok then
        core.log.error("failed to connect push gateway: ", err, " addr:", timer.addr)
        release_timer(timer)
        return
    end

    core.log.info("connect push gateway success: ", timer.addr)

    timer.ws_cli = ws_cli

    local from_co, err = thread_spawn(from_push_gateway_thread, timer)
    if not from_co then
        core.log.error("failed to start `from push gateway` thread: ", err)
        release_timer(timer)
        return
    end

    local to_co, err = thread_spawn(to_push_gateway_thread, timer)
    if not to_co then
        core.log.error("failed to start `to push gateway` thread: ", err)
        release_timer(timer)
        return
    end

    -- sync all topics to push gateway when start/restart
    local all_topics = topic.get_all_topics()
    if all_topics and #all_topics > 0 then
        local msg = {
            action = "sub_put",
            msgid = ngx_time() .. "",
            worker_name = misc_utils.get_worker_uni_id(),
            topics = all_topics,
        }
        queue.push(timer.queue, msg)
        timer.sema:post(1)
    end

    local ok, err = wait(from_co, to_co)
    if not ok then
        core.log.warn("failed to wait push gateway threads: ", err)
        release_timer(timer)
    end

    thread_kill(from_co)
    thread_kill(to_co)
end


function _M.notify(action, msgId, topics)
    local msg = {
        action = action,
        msgid = msgId,
        worker_name = misc_utils.get_worker_uni_id(),
        topics = topics,
    }

    for _, timer in pairs(push_gateway_timers) do
        if not timer.diffing then
            queue.push(timer.queue, msg)
            timer.sema:post(1)
        else
            queue.push(timer.diffing_queue, msg)
        end
    end
end


local function compare_topic(a, b)
    return a < b
end


local function topics_diff()
    for _, timer in pairs(push_gateway_timers) do
        -- stop sync topics to push gateway when diffing
        timer.diffing = true
    end

    local all_topics = topic.get_all_topics() or {}
    core.table.sort(all_topics, compare_topic)
    local md5 = ngx_md5(core.table.concat(all_topics, ","))

    local msg = {
        action = "topics_diff",
        msgid = ngx_time() .. "",
        size = #all_topics,
        md5 = md5,
    }

    for _, timer in pairs(push_gateway_timers) do
        queue.push(timer.queue, msg)
        timer.sema:post(1)

        -- resume sync topics to push gateway
        timer.diffing = false

        for _, topic in ipairs(timer.diffing_queue) do
            queue.push(timer.queue, topic)
            timer.sema:post(1)
        end

        timer.diffing_queue = {}
    end
end


local refresh_connections
refresh_connections = function (premature)
    if premature then
        return
    end

    local metadata = plugin.plugin_metadata("ht-ws-msg-pub")
    if metadata then
        local addrs = metadata.value.api7_push_gateway_addrs
        local new_addrs, useless_timers = addrs_diff(addrs)

        -- remove the connections that not in addrs
        if #useless_timers > 0 then
            for _, addr in ipairs(useless_timers) do
                local timer = push_gateway_timers[addr]
                if timer then
                    release_timer(timer)
                    core.log.warn("release the timer for addr: ", addr)
                end
            end
        end

        -- create the connections that not in push_gateway_timers
        if #new_addrs > 0 then
            for _, addr in ipairs(new_addrs) do
                apply_timer(push_gateway_handler, addr)
                core.log.info("apply timer for addr: ", addr)
            end
        end
    end

    local attr = plugin.plugin_attr("ht-ws-msg-pub")
    local connections_refresh_interval = attr and attr.connections_refresh_interval or 1

    local ok, err = timer_at(connections_refresh_interval, refresh_connections)
    if not ok then
        core.log.error("failed to create the timer to refresh connections to push gateway: ", err)
        return
    end
end


local check_topics_diff
local topic_diff_interval = 30
check_topics_diff = function (premature)
    if premature then
        return
    end

    local attr = plugin.plugin_attr("ht-ws-msg-pub")
    local topic_diff_interval = attr and attr.topic_diff_interval or 30
    if topic_diff_interval == 0 then
        return
    end

    topics_diff()

    local ok, err = timer_at(topic_diff_interval, check_topics_diff)
    if not ok then
        core.log.error("failed to create the timer to sync topics to push gateway: ", err)
        return
    end
end


function _M.init()
    timer_at(0, refresh_connections)

    local real_interval = topic_diff_interval + math_random(1, 30)
    local ok, err = timer_at(real_interval, check_topics_diff)
    if not ok then
        core.log.error("failed to create the timer to sync topics to push gateway: ", err)
        return
    end
end


return _M
