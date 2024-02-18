local require = require
local str_format = string.format
local str_sub = string.sub
local str_char = string.char
local tab_concat = table.concat
local tonumber = tonumber
local bit = require("bit")
local lshift = bit.lshift
local ngx = ngx
local core = require("apisix.core")
local decoder = require("apisix.plugins.ht-msg-sub.ms1975_decoder")

local MAGIC_LENGTH = 2
local BODY_LEN_LENGTH = 4

local _M = {}


local function read_data(sk, len)
    local p, err = sk:receive(len)
    if not p then
        return nil, err
    end

    return p
end


local function hex2int(hex)
    local len0 = string.byte(hex,1)
    local len1 = string.byte(hex,2)
    local len2 = string.byte(hex,3)
    local len3 = string.byte(hex,4)

    return len0 + lshift(len1, 8) + lshift(len2, 16) + lshift(len3, 24)
end


local function int2hex(i)
    local hex_str = str_format("%08x", i)

    local len0 = str_char(tonumber(str_sub(hex_str, 7, 8), 16))
    local len1 = str_char(tonumber(str_sub(hex_str, 5, 6), 16))
    local len2 = str_char(tonumber(str_sub(hex_str, 3, 4), 16))
    local len3 = str_char(tonumber(str_sub(hex_str, 1, 2), 16))

    return len0 .. len1 .. len2 .. len3
end


function _M.start(delay)
    local sock = ngx.req.socket()

    while true do
        local magic, err = read_data(sock, MAGIC_LENGTH)
        if magic == nil then
            core.log.error("read data error: ", err)
            return
        end

        -- get body length
        local body_len, err = read_data(sock, BODY_LEN_LENGTH)
        if body_len == nil then
            core.log.error("read body length error: ", err)
            return
        end

        -- read body
        local body, err = read_data(sock, hex2int(body_len))
        if body == nil then
            core.log.error("read body error: ", err)
            return
        end

        local msg, err = decoder.decode(magic .. body_len .. body)
        if not msg then
            core.log.error("failed to decode body: ", err)
            return
        end

        -- repace frontend topic to backend topic
        if msg.body.topics then
            local addon = false
            for i, topic in ipairs(msg.body.topics) do
                if topic == "frontend-topic" then
                    msg.body.topics[i] = "backend-topic"
                    addon = true
                end
            end
            if addon then
                core.table.insert(msg.body.topics, "sig-test")
            end
        end

        local resp = {
            status = 200,
            body = {
                code = "0",
                message = "upstream success",
                msgId = msg.header.msgId,
                resultData = "null"
            },
            header = {
                topics = msg.body.topics and tab_concat(msg.body.topics, ",") or nil,
            }
        }

        if msg.header._url_segment then
            core.log.info("upstream received _url_segment: ", msg.header._url_segment)
        end

        if msg.header.wanted_code then
            if msg.header.wanted_code == "-1" then
                -- send invalid response
                sock:send("")
                goto CONTINUE
            end

            resp.body.code = msg.header.wanted_code
            resp.body.message = "wanted code: " .. msg.header.wanted_code
        end

        if msg.body and msg.body.wanted_decode_error then
            resp.body.wanted_decode_error = msg.body.wanted_decode_error
        end

        local resp_str = core.json.encode(resp)
        local magic = str_char(tonumber("B7", 16)) .. str_char(tonumber("00", 16))

        local resp_data = magic .. int2hex(#resp_str) .. resp_str

        if delay and delay > 0 then
            ngx.sleep(delay)
        end

        sock:send(resp_data)

        ::CONTINUE::
    end
end


return _M
