local core = require("apisix.core")

local str_format    = string.format

local _M = {}


local function parse_service_name(service_name)
    local pattern = "^(.*)/(.*)/(.*)/(.*)$" -- registry_id/namespace_id/group_name/service_name
    local match = ngx.re.match(service_name, pattern, "jo")
    if not match then
        core.log.error("get unexpected upstream service_name: ", service_name)
        return ""
    end

    return match[1], match[2], match[3], match[4]
end

_M.parse_service_name = parse_service_name

local function iter_and_add_service(services, hash, id, values)
    if not values then
        return
    end

    for _, value in core.config_util.iterate_values(values) do
        local conf = value.value
        if not conf then
            goto CONTINUE
        end

        local upstream
        if conf.upstream then
            upstream = conf.upstream
        else
            upstream = conf
        end

        if upstream.discovery_type ~= "nacos" then
            goto CONTINUE
        end

        if hash[upstream.service_name] then
            goto CONTINUE
        end

        local service_registry_id, namespace_id, group_name, name = parse_service_name(upstream.service_name)
        if service_registry_id ~= id then
            goto CONTINUE
        end

        core.table.insert(services, {
            name = name,
            namespace_id = namespace_id,
            group_name = group_name,
            service_name = upstream.service_name,
        })

        ::CONTINUE::
    end
end


function _M.get_nacos_services(service_registry_id)
    local services = {}
    local services_hash = {}

    -- here we use lazy load to work around circle dependency
    local get_upstreams = require('apisix.upstream').upstreams
    local get_routes = require('apisix.router').http_routes
    local get_stream_routes = require('apisix.router').stream_routes
    local get_services = require('apisix.http.service').services
    local values = get_upstreams()
    iter_and_add_service(services, services_hash, service_registry_id, values)
    values = get_routes()
    iter_and_add_service(services, services_hash, service_registry_id, values)
    values = get_services()
    iter_and_add_service(services, services_hash, service_registry_id, values)
    values = get_stream_routes()
    iter_and_add_service(services, services_hash, service_registry_id, values)
    return services
end


function _M.generate_signature(group_name, service_name, access_key, secret_key)
    local str_to_sign = ngx.now() * 1000 .. '@@' .. group_name .. '@@' .. service_name
    return access_key, str_to_sign, ngx.encode_base64(ngx.hmac_sha1(secret_key, str_to_sign))
end


function _M.generate_request_params(params)
    if params == nil then
        return ""
    end

    local args = ""
    local first = false
    for k, v in pairs(params) do
        if not first then
            args = str_format("%s&%s=%s", args, k, v)
        else
            first = true
            args = str_format("%s=%s", k, v)
        end
    end

    return args
end


function _M.match_metdata(node_metadata, upstream_metadata)
    if upstream_metadata == nil then
        return true
    end

    if not node_metadata then
        node_metadata = {}
    end

    for k, v in pairs(upstream_metadata) do
        if not node_metadata[k] or node_metadata[k] ~= v then
            return false
        end
    end

    return true
end


return _M
