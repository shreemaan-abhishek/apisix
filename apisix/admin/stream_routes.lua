local core = require("apisix.core")
local resource = require("apisix.admin.resource")
local stream_route_checker = require("apisix.stream.router.ip_port").stream_route_checker


local function check_conf(id, conf, need_id, schema)
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return nil, {error_msg = "invalid configuration: " .. err}
    end

    local upstream_id = conf.upstream_id
    if upstream_id then
        local key = "/upstreams/" .. upstream_id
        local res, err = core.etcd.get(key)
        if not res then
            return nil, {error_msg = "failed to fetch upstream info by "
                                     .. "upstream id [" .. upstream_id .. "]: "
                                     .. err}
        end

        if res.status ~= 200 then
            return nil, {error_msg = "failed to fetch upstream info by "
                                     .. "upstream id [" .. upstream_id .. "], "
                                     .. "response code: " .. res.status}
        end
    end

    local service_id = conf.service_id
    if service_id then
        local key = "/services/" .. service_id
        local res, err = core.etcd.get(key)
        if not res then
            return nil, {error_msg = "failed to fetch service info by "
                    .. "service id [" .. service_id .. "]: "
                    .. err}
        end

        if res.status ~= 200 then
            return nil, {error_msg = "failed to fetch service info by "
                    .. "service id [" .. service_id .. "], "
                    .. "response code: " .. res.status}
        end
    end

    local ok, err = stream_route_checker(conf, true)
    if not ok then
        return nil, {error_msg = err}
    end

    return true
end


return resource.new({
    name = "stream_routes",
    kind = "stream route",
    schema = core.schema.stream_route,
    checker = check_conf,
    unsupported_methods = {"patch"}
})
