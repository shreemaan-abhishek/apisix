local ngx = ngx
local log = require("apisix.core.log")
local string_format = string.format
local setmetatable = setmetatable

local _M = {}
local mt = { __index = _M }

function _M.new(options)
    if not options.name then
        return nil, "shared dictionary name is mandatory"
    end

    local dict = ngx.shared[options.name]
    if not dict then
        return nil,
            string_format("shared dictionary with name \"%s\" is not configured",
                options.name)
    end

    return setmetatable({
        dict = dict,
    }, mt)
end

function _M.incr(self, key, delta, expiry)
    local new_value, err, forcible = self.dict:incr(key, delta, 0, expiry)
    if err then
        return nil, err
    end

    if forcible then
        log.warn("shared dictionary is full, removed valid key(s) to store the new one")
    end

    return new_value
end

function _M.get(self, key)
    local value, err = self.dict:get(key)
    if not value then
        return nil, err
    end

    return value
end

return _M
