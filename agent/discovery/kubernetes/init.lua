local ngx = ngx
local ipairs = ipairs
local pairs = pairs
local string = string
local tonumber = tonumber
local tostring = tostring
local os = os
local pcall = pcall
local setmetatable = setmetatable
local is_http = ngx.config.subsystem == "http"
local support_process, process = pcall(require, "ngx.process")
local core = require("apisix.core")
local util = require("apisix.cli.util")
local local_conf = require("apisix.core.config_local").local_conf()
local informer_factory = require("agent.discovery.kubernetes.informer_factory")


local ctx = {}

local endpoint_lrucache = core.lrucache.new({
    ttl = 300,
    count = 1024
})

local endpoint_buffer = {}

local function sort_nodes_cmp(left, right)
    if left.host ~= right.host then
        return left.host < right.host
    end

    return left.port < right.port
end


local function on_endpoint_modified(handle, endpoint)
    if handle.namespace_selector and
            not handle:namespace_selector(endpoint.metadata.namespace) then
        return
    end

    core.log.debug(core.json.delay_encode(endpoint))
    core.table.clear(endpoint_buffer)

    local subsets = endpoint.subsets
    for _, subset in ipairs(subsets or {}) do
        if subset.addresses then
            local addresses = subset.addresses
            for _, port in ipairs(subset.ports or {}) do
                local port_name
                if port.name then
                    port_name = port.name
                elseif port.targetPort then
                    port_name = tostring(port.targetPort)
                else
                    port_name = tostring(port.port)
                end

                local nodes = endpoint_buffer[port_name]
                if nodes == nil then
                    nodes = core.table.new(0, #subsets * #addresses)
                    endpoint_buffer[port_name] = nodes
                end

                for _, address in ipairs(subset.addresses) do
                    core.table.insert(nodes, {
                        host = address.ip,
                        port = port.port,
                        weight = handle.default_weight
                    })
                end

                -- Different from Apache APISIX, we both set nodes to port_name and port.port
                endpoint_buffer[tostring(port.port)] = core.table.deepcopy(nodes)
            end
        end
    end

    for _, ports in pairs(endpoint_buffer) do
        for _, nodes in pairs(ports) do
            core.table.sort(nodes, sort_nodes_cmp)
        end
    end

    --- Different from Apache APISIX, we add registry_id to endpoint_key
    local endpoint_key = handle.registry_id .. "/" .. endpoint.metadata.namespace .. "/" .. endpoint.metadata.name
    local endpoint_content = core.json.encode(endpoint_buffer, true)
    local endpoint_version = ngx.crc32_long(endpoint_content)

    local _, err
    _, err = handle.endpoint_dict:safe_set(endpoint_key .. "#version", endpoint_version)
    if err then
        core.log.error("set endpoint version into discovery DICT failed, ", err)
        return
    end
    _, err = handle.endpoint_dict:safe_set(endpoint_key, endpoint_content)
    if err then
        core.log.error("set endpoint into discovery DICT failed, ", err)
        handle.endpoint_dict:delete(endpoint_key .. "#version")
    end
end


local function on_endpoint_deleted(handle, endpoint)
    if handle.namespace_selector and
            not handle:namespace_selector(endpoint.metadata.namespace) then
        return
    end

    core.log.debug(core.json.delay_encode(endpoint))
    --- Different from Apache APISIX, we add registry_id to endpoint_key
    local endpoint_key = handle.registry_id .. "/" .. endpoint.metadata.namespace .. "/" .. endpoint.metadata.name
    handle.endpoint_dict:delete(endpoint_key .. "#version")
    handle.endpoint_dict:delete(endpoint_key)
end


local function pre_list(handle)
    handle.endpoint_dict:flush_all()
end


local function post_list(handle)
    handle.endpoint_dict:flush_expired()
end


local function setup_label_selector(conf, informer)
    informer.label_selector = conf.label_selector
end


local function setup_namespace_selector(conf, informer)
    local ns = conf.namespace_selector
    if ns == nil then
        informer.namespace_selector = nil
        return
    end

    if ns.equal then
        informer.field_selector = "metadata.namespace=" .. ns.equal
        informer.namespace_selector = nil
        return
    end

    if ns.not_equal then
        informer.field_selector = "metadata.namespace!=" .. ns.not_equal
        informer.namespace_selector = nil
        return
    end

    if ns.match then
        informer.namespace_selector = function(self, namespace)
            local match = conf.namespace_selector.match
            local m, err
            for _, v in ipairs(match) do
                m, err = ngx.re.match(namespace, v, "jo")
                if m and m[0] == namespace then
                    return true
                end
                if err then
                    core.log.error("ngx.re.match failed: ", err)
                end
            end
            return false
        end
        return
    end

    if ns.not_match then
        informer.namespace_selector = function(self, namespace)
            local not_match = conf.namespace_selector.not_match
            local m, err
            for _, v in ipairs(not_match) do
                m, err = ngx.re.match(namespace, v, "jo")
                if m and m[0] == namespace then
                    return false
                end
                if err then
                    return false
                end
            end
            return true
        end
        return
    end

    return
end


local function read_env(key)
    if #key > 3 then
        local first, second = string.byte(key, 1, 2)
        if first == string.byte('$') and second == string.byte('{') then
            local last = string.byte(key, #key)
            if last == string.byte('}') then
                local env = string.sub(key, 3, #key - 1)
                local value = os.getenv(env)
                if not value then
                    return nil, "not found environment variable " .. env
                end
                return value
            end
        end
    end
    return key
end

local function read_token(token_file)
    local token, err = util.read_file(token_file)
    if err then
        return nil, err
    end

    -- remove possible extra whitespace
    return util.trim(token)
end

local function get_apiserver(conf)
    local apiserver = {
        schema = "",
        host = "",
        port = "",
    }

    apiserver.schema = conf.service.schema
    if apiserver.schema ~= "http" and apiserver.schema ~= "https" then
        return nil, "service.schema should set to one of [http,https] but " .. apiserver.schema
    end

    local err
    apiserver.host, err = read_env(conf.service.host)
    if err then
        return nil, err
    end

    if apiserver.host == "" then
        return nil, "service.host should set to non-empty string"
    end

    local port
    port, err = read_env(conf.service.port)
    if err then
        return nil, err
    end

    apiserver.port = tonumber(port)
    if not apiserver.port or apiserver.port <= 0 or apiserver.port > 65535 then
        return nil, "invalid port value: " .. (apiserver.port or "nil")
    end

    if conf.client.token then
        local token, err = read_env(conf.client.token)
        if err then
            return nil, err
        end
        apiserver.token = util.trim(token)
    elseif conf.client.token_file and conf.client.token_file ~= "" then
        setmetatable(apiserver, {
            __index = function(_, key)
                if key ~= "token" then
                    return
                end

                local token_file, err = read_env(conf.client.token_file)
                if err then
                    core.log.error("failed to read token file path: ", err)
                    return
                end

                local token, err = read_token(token_file)
                if err then
                    core.log.error("failed to read token from file: ", err)
                    return
                end
                core.log.debug("re-read the token value")
                return token
            end
        })
    else
        return nil, "one of [client.token,client.token_file] should be set but none"
    end

    if apiserver.schema == "https" and apiserver.token == "" then
        return nil, "apiserver.token should set to non-empty string when service.schema is https"
    end

    return apiserver
end

local function create_endpoint_lrucache(endpoint_dict, endpoint_key)
    local endpoint_content = endpoint_dict:get_stale(endpoint_key)
    if not endpoint_content then
        core.log.error("get empty endpoint content from discovery DIC, this should not happen ",
                endpoint_key)
        return nil
    end

    local endpoint = core.json.decode(endpoint_content)
    if not endpoint then
        core.log.error("decode endpoint content failed, this should not happen, content: ",
                endpoint_content)
        return nil
    end

    return endpoint
end


local _M = {
    version = "0.0.1"
}


local function start_fetch(handle)
    if handle.checker ~= nil then
        handle.checker:start()
    end

    local timer_runner
    timer_runner = function(premature)
        if premature then
            return
        end

        if handle.stop then
            core.log.info("stop fetching, kind: ", handle.kind)
            return
        end

        local ok, status = pcall(handle.list_watch, handle, handle.apiserver)

        local retry_interval = 0
        if not ok then
            core.log.error("list_watch failed, kind: ", handle.kind,
                    ", reason: ", "RuntimeException", ", message : ", status)
            retry_interval = 40
        elseif not status then
            retry_interval = 40
        end

        ngx.timer.at(retry_interval, timer_runner)
    end
    ngx.timer.at(0, timer_runner)
end

local function get_endpoint_dict(id)
    return ngx.shared.kubernetes
end


local function multiple_mode_init(confs)

    if process.type() ~= "privileged agent" then
        return
    end

    local tmp = core.table.new(#confs, 0)
    for _, conf in ipairs(confs) do
        tmp[conf.id] = true
    end

    for _, conf in ipairs(confs) do
        local id = conf.id
        local version = ngx.md5(core.json.encode(conf, true))

        if ctx[id] then
            local old = ctx[id]
            if old.version == version then
                core.log.info("the kubernetes configuration doesn't changed, id: ", id, " conf: ",
                        core.json.delay_encode(conf))
                goto CONTINUE
            end

            --- It means that the configuration has been changed.So we need to stop the previous informer
            old.informer.stop = true
        end

        local endpoint_dict = get_endpoint_dict()
        if not endpoint_dict then
            core.log.error(string.format("failed to get lua_shared_dict: ngx.shared.kubernetes, ") ..
                    "please check your APISIX version")
        end

        local apiserver, err = get_apiserver(conf)
        if err then
            core.log.error(err)
            goto CONTINUE
        end

        local default_weight = conf.default_weight or 50

        local endpoints_informer, err = informer_factory.new("", "v1", "Endpoints", "endpoints", "")
        if err then
            core.log.error(err)
            return
        end

        setup_namespace_selector(conf, endpoints_informer)
        setup_label_selector(conf, endpoints_informer)

        endpoints_informer.on_added = on_endpoint_modified
        endpoints_informer.on_modified = on_endpoint_modified
        endpoints_informer.on_deleted = on_endpoint_deleted
        endpoints_informer.pre_list = pre_list
        endpoints_informer.post_list = post_list
        endpoints_informer.registry_id = id

        local checker
        if conf.check then
            local health_check = require("resty.healthcheck")
            checker = health_check.new({
                name = conf.id,
                shm_name = "kubernetes",
                checks = conf.check,
            })

            local ok, err = checker:add_target(conf.check.active.host, conf.check.active.port, nil, false)
            if not ok then
                core.log.error("failed to add health check target", core.json.encode(conf))
                goto CONTINUE
            end

            core.log.info("success to add health checker, conf.id ", conf.id, " host ", conf.check.active.host, " port ", conf.check.active.port)
        end

        ctx[id] = setmetatable({
            endpoint_dict = endpoint_dict,
            apiserver = apiserver,
            default_weight = default_weight,
            version = version,
            informer = endpoints_informer,
            checker = checker,
        }, { __index = endpoints_informer })

        ::CONTINUE::
    end

    for id, item in pairs(ctx) do
        if tmp[id] then
          start_fetch(item)
        else
          --- This item is not in the new configuration, it means that it has been deleted from the control plane
          --- So we should stop the informer
          local old = ctx[id]
          old.informer.stop = true
          old.checker:clear()
          ctx[id] = nil
        end
    end
end


local function multiple_mode_nodes(service_name)
    local pattern = "^(.*)/(.*/.*):(.*)$" -- id/namespace/name:port_name
    local match = ngx.re.match(service_name, pattern, "jo")
    if not match then
        core.log.error("get unexpected upstream service_name:　", service_name)
        return nil
    end

    local id = match[1]
    local endpoint_dict = ngx.shared.kubernetes
    if not endpoint_dict then
        core.log.error("id not exist: ", id)
        return nil
    end

    --- Different from Apache APISIX, we add the registry_id to the key
    local endpoint_key = id .. "/" .. match[2]
    local endpoint_port = match[3]
    local endpoint_version = endpoint_dict:get_stale(endpoint_key .. "#version")
    if not endpoint_version then
        core.log.info("get empty endpoint version from discovery DICT ", endpoint_key)
        return nil
    end

    local endpoint = endpoint_lrucache(service_name, endpoint_version,
            create_endpoint_lrucache, endpoint_dict, endpoint_key)
    if not endpoint then
        return nil
    end

    return endpoint[endpoint_port]
end

function _M.list_all_services()
    local endpoint_dict = get_endpoint_dict()
    local keys = endpoint_dict:get_keys(0)
    if not keys then
        return {}
    end

    local result = {}
    for _, key in ipairs(keys) do
        if not core.string.find(key, "#version") then
            goto CONTINUE
        end

        local pattern = "^(.*)/(.*)/(.*)#version$" -- id/namespace/name#version
        local match = ngx.re.match(key, pattern, "jo")
        if not match then
            core.log.error("get unexpected upstream service_name:　", service_name)
            goto CONTINUE
        end

        local service_registry_id = match[1]
        local namespace = match[2]
        local service_name = match[3]
        local endpoint_key = service_registry_id .. "/" .. namespace .. "/" .. service_name
        if result[service_registry_id] == nil then
            result[service_registry_id] = {}
        end

        if result[service_registry_id][namespace] == nil then
            result[service_registry_id][namespace] = {}
        end

        local endpoint_version = endpoint_dict:get_stale(endpoint_key)
        if not endpoint_version then
            core.log.info("get empty endpoint version from discovery DICT ", endpoint_key)
            goto CONTINUE
        end

        local content = endpoint_lrucache(service_name, endpoint_version, create_endpoint_lrucache, endpoint_dict, endpoint_key)
        for port in pairs(content) do
            if tonumber(port) then
                local len = #result[service_registry_id][namespace]
                result[service_registry_id][namespace][len + 1] = service_name .. ":" .. port
            end
        end

        ::CONTINUE::

    end

    return result
end


function _M.init_worker()
    if not support_process then
        core.log.error("kubernetes discovery not support in subsystem: ", ngx.config.subsystem,
                       ", please check if your openresty version >= 1.19.9.1 or not")
        return
    end

    local local_conf = require("apisix.core.config_local").local_conf(true)
    local discovery_conf = local_conf.api7_discovery and local_conf.api7_discovery.kubernetes or {}

    core.log.info("kubernetes discovery conf: ", core.json.delay_encode(discovery_conf))

    _M.nodes = multiple_mode_nodes
    multiple_mode_init(discovery_conf)
end


function _M.get_health_checkers()
    local result = core.table.new(0, 4)
    if ctx == nil then
        return result
    end

    for id in pairs(ctx) do
        local health_check = require("resty.healthcheck")
        local list = health_check.get_target_list(id, "kubernetes")
        if list then
            result[id] = list
        end
    end

    return result
end

return _M
