local require = require
local core   = require("apisix.core")

local _M = {}

_M.decode = core.json.decode
_M.encode = core.json.encode


function _M.encode_error(status, msg_id, code, msg)
    local resp = {
        body = {
            msgId = msg_id,
            code = code,
            message = msg,
        },
        status = status,
    }

    return _M.encode(resp)
end


return _M
