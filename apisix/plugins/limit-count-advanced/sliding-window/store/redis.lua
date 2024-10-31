local ngx_null  = ngx.null
local str       = require("apisix.core.string")

local _M = {}


local incr_script = str.compress_script([=[
    local ttl = redis.call('pttl', KEYS[1])
    if ttl < 0 then
        redis.call('set', KEYS[1], ARGV[1], 'EX', ARGV[2])
        return tonumber(ARGV[1])
    end
    return redis.call('incrby', KEYS[1], ARGV[1])
]=])


-- TODO: keepalive or close
function _M.incr(self, key, delta, expiry, red)
    --                                          nk  key1  argv1  argv2
    local new_value, err = red:eval(incr_script, 1, key, delta, expiry)
    if err then
        return nil, err
    end

    if not new_value then
        return nil, "malformed redis response while calling incr"
    end

    return new_value
end


-- TODO: keepalive or close
function _M.get(self, key, red)
    local value, err = red:get(key)
    if not value or value == ngx_null then
        return nil, err
    end

    value = tonumber(value)
    if not value then -- maybe warn log?
        return nil, "redis counter is not a number the value could have been modified"
    end

    return value, nil
end

return _M
