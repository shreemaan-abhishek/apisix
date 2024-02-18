-- just for test, will be replaced by user's file
local str_format = string.format
local str_sub = string.sub
local str_char = string.char
local tonumber = tonumber
local require = require
local core = require("apisix.core")

local _M = {}


local function int2hex(i)
    local hex_str = str_format("%08x", i)

    local len0 = str_char(tonumber(str_sub(hex_str, 7, 8), 16))
    local len1 = str_char(tonumber(str_sub(hex_str, 5, 6), 16))
    local len2 = str_char(tonumber(str_sub(hex_str, 3, 4), 16))
    local len3 = str_char(tonumber(str_sub(hex_str, 1, 2), 16))

    return len0 .. len1 .. len2 .. len3
end


function _M.decode(body)
    local body = str_sub(body, 7)

    local msg = core.json.decode(body)

    if msg and msg.body and msg.body.wanted_decode_error then
        return nil, msg.body.wanted_decode_error
    end

    return msg
end


function _M.encode(uri, header, body)
    local req = {
        uri = uri,
        header = header,
        body = body,
    }

    if body and body.wanted_encode_error then
        return nil, body.wanted_encode_error
    end

    local req_str = core.json.encode(req)
    local magic = str_char(tonumber("B7", 16)) .. str_char(tonumber("00", 16))

    return magic .. int2hex(#req_str) .. req_str
end


return _M
