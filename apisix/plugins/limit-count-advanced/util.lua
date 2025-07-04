local redis_new = require("resty.redis").new
local redis_sentinel = require("resty.redis.connector")
local _M = {}


function _M.redis_cli(conf)
    local red = redis_new()
    local timeout = conf.redis_timeout or 1000    -- 1sec

    red:set_timeouts(timeout, timeout, timeout)

    local sock_opts = {
        ssl = conf.redis_ssl,
        ssl_verify = conf.redis_ssl_verify
    }

    local ok, err = red:connect(conf.redis_host, conf.redis_port or 6379, sock_opts)
    if not ok then
        return nil, err
    end

    local count
    count, err = red:get_reused_times()
    if 0 == count then
        if conf.redis_password and conf.redis_password ~= '' then
            local ok, err
            if conf.redis_username then
                ok, err = red:auth(conf.redis_username, conf.redis_password)
            else
                ok, err = red:auth(conf.redis_password)
            end
            if not ok then
                return nil, err
            end
        end

        -- select db
        if conf.redis_database ~= 0 then
            local ok, err = red:select(conf.redis_database)
            if not ok then
                return nil, "failed to change redis db, err: " .. err
            end
        end
    elseif err then
        -- core.log.info(" err: ", err)
        return nil, err
    end
    return red, nil
end

function _M.redis_cli_sentinel(conf)
    local redis_conf = {
        password = conf.redis_password,
        db = conf.redis_database or 0,
        sentinels = conf.redis_sentinels or {},
        master_name = conf.redis_master_name,
        role = conf.redis_role or "master",
        connect_timeout = conf.redis_connect_timeout or 1000,
        read_timeout = conf.redis_read_timeout or 1000,
        keepalive_timeout = conf.redis_keepalive_timeout or 60000,
    }

    local sentinel_client, err = redis_sentinel.new(redis_conf)
    if not sentinel_client then
        return nil, "failed to create redis client: " .. (err or "unknown error")
    end

    local red, err = sentinel_client:connect()
    if not red then
        return nil, "redis connection failed: " .. (err or "unknown error")
    end
    return red, nil
end
return _M
