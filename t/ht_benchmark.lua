local spawn = ngx.thread.spawn
local wait = ngx.thread.wait
local say = ngx.say
local require = require
local ws_client = require("resty.websocket.client")


local total_requested = 0
local total_thread = 0
local thread_requests = {}

local CONNECTION_DEFAULT = 1
local connection = CONNECTION_DEFAULT
local DURATION_DEFAULT = 60
local duration = DURATION_DEFAULT

local do_exiting = false

local n = #arg
for i = 1, n, 2 do
    if arg[i] == "-d" then
        duration = tonumber(arg[i+1]) or DURATION_DEFAULT
    elseif arg[i] == "-conn" then
        connection = tonumber(arg[i+1]) or CONNECTION_DEFAULT
    elseif arg[i] == "-h" then
        ngx.say("Usage: lua benchmark.lua [-d duration] [-conn connection] [-p protocol]")
        ngx.exit(0)
        return
    end
end


local receive_start_time = 0
local function request(thread_idx)
    local ws = ws_client:new()
    local addr = "ws://127.0.0.1:9082/msg-pub"
    local ok, err = ws:connect(addr)
    if not ok then
        print("thread[", thread_idx, "] ", "failed to connect " .. addr)
        return 1
    else
        print("thread[", thread_idx, "] ", "connected to " .. addr)
    end

    thread_requests[thread_idx] = 0

    -- subscribe topics
    local ss = [[{
        "uri":"/60150/ormp/subscribe/accountSubscribe",
        "header": {
            "ts": 132132132,
            "msgId": "2",
            "Content-Type": "json",
            "client-metadata": {}
        },
        "body":{
              "topics":["hq_100001_0", "hq_100001_]] .. thread_idx .. [["]
        }
    }]]
    local _, err = ws:send_text(ss)

    print("thread[", thread_idx, "] ", "subscribe request: ", ss)

    if err then
        print("failed to send text: "..err)
        ngx.exit()
    end

    -- receive the result of subscription
    local raw_data, _, err = ws:recv_frame()
    if not raw_data then
        print("failed to receive the frame: ", err)
        ngx.exit(444)
    end

    print("thread[", thread_idx, "] ", "subscribe response: ", raw_data)

    while not do_exiting do
        local raw_data, _, err = ws:recv_frame()
        if not raw_data then
            ngx.say("thread[", thread_idx, "] ", "failed to receive message, error: ", err)
            return 0.1
        end

        if receive_start_time == 0 then
            ngx.update_time()
            receive_start_time = ngx.now()
        end

        thread_requests[thread_idx] = thread_requests[thread_idx] + 1

        if thread_requests[thread_idx] % 1000 == 0 then
            ngx.update_time()
            local elapsed = ngx.now() - receive_start_time
            print("thread[", thread_idx, "] ", "received ", thread_requests[thread_idx], " messages, elapsed: ", string.format("%.3f", elapsed), " sec")
        end
    end

    ws:close()

    return 0
end

local function benchmark()
    total_thread = total_thread + 1
    local thread_idx = total_thread

    while not do_exiting do
        local sleep_sec = request(thread_idx)
        if sleep_sec > 0 then
            ngx.sleep(sleep_sec)
        end
    end
end


ngx.update_time()
local benchmark_start_time = ngx.now()
local function check_timeout()
    local elapsed = 0
    while elapsed <= duration do
        ngx.sleep(0.1)
        ngx.update_time()
        elapsed = ngx.now() - benchmark_start_time
    end
end

-- start benchmark threads
local threads = {}
for i = 1, connection do
    threads[i] = spawn(benchmark)
end

-- start check timeout thread
say("============start benchmark============")
say("duration time: ", duration, " sec")
say("connection   : ", connection)
say("protocol     : ", protocol_name)
say("")
local check_time_thread = spawn(check_timeout)
local ok, err = wait(check_time_thread)

-- kill all threads
do_exiting = true
for i, thread in ipairs(threads) do
    -- ngx.thread.kill(thread)
    wait(thread)
end

-- print benchmark result
local benchmark_end_time = ngx.now()
local total_elapsed = benchmark_end_time - receive_start_time

for i, cnt in pairs(thread_requests) do
    total_requested = total_requested + thread_requests[i]
end

say("")
say("Request count: ", total_requested)
say("Elapsed time : ", string.format("%.3f", total_elapsed), " sec")
say("QPS          : ", string.format("%.0f", total_requested/total_elapsed))
