local require       = require
local type          = type
local core          = require("apisix.core")
local config_local  = require("apisix.core.config_local")
local plugin        = require("apisix.plugin")
local http          = require("resty.http")


local _M = {}


local function get_node_listen_ports(cfg)
    local node_listen = {}

    if type(cfg) == "number" then
        table.insert(node_listen, cfg)
    elseif type(cfg) == "table" then
        for _, value in ipairs(cfg) do
            if type(value) == "number" then
                table.insert(node_listen, value)
            elseif type(value) == "table" then
                local port = value.port
                if port == nil then
                    port = 9080
                end
                table.insert(node_listen, port)
            end
        end
    end

    return node_listen
end


local function get_ssl_ports(cfg)
    local ssl_listen = {}
    if cfg.enable == false then
        return ssl_listen
    end
    for _, value in ipairs(cfg.listen) do
        if type(value) == "number" then
            table.insert(ssl_listen, value)
        elseif type(value) == "table" then
            local port = value.port
            if port == nil then
                port = 9443
            end
            table.insert(ssl_listen, port)
        end
    end
    return ssl_listen
end


function _M.get_listen_ports()
    local local_conf = config_local.local_conf()

    local node_listen = core.table.try_read_attr(local_conf, "apisix", "node_listen")
    local ssl = core.table.try_read_attr(local_conf, "apisix", "ssl")

    local node_listen_ports = get_node_listen_ports(node_listen)
    local ssl_ports = get_ssl_ports(ssl)

    local ports = {}
    if node_listen_ports ~= nil then
        for _, v in ipairs(node_listen_ports) do
            table.insert(ports, v)
        end
    end

    if ssl_ports ~=nil then
        for _, v in ipairs(ssl_ports) do
            table.insert(ports, v)
        end
    end

    return ports
end


function _M.get_control_plane_revision()
    local config = core.config.new()

    if config.type == "etcd" then
        local res, _ = config:getkey("/phantomkey")
        if res and res.headers then
            return res.headers["X-Etcd-Index"]
        end
    end

    return "unknown"
end


local metric_url
function _M.fetch_nginx_metrics(http_timeout)
    if not metric_url then
        local attr = plugin.plugin_attr("prometheus")
        local metric_host = attr.export_addr and attr.export_addr.host or "127.0.0.1"
        local metric_port = attr.export_addr and attr.export_addr.port or "9091"
        local metric_uri = "/apisix/collect_nginx_status"
        metric_url = "http://" .. metric_host .. ":" .. metric_port .. metric_uri
    end

    local httpc, err = http.new()
    if err then
        return nil, err
    end

    httpc:set_timeout(http_timeout)
    return httpc:request_uri(metric_url, { method="GET" })
end


function _M.parse_resp(response_body)
    local resp, err
    if type(response_body) == "string" then
        resp, err = core.json.decode(response_body)
    elseif type(response_body) == "table" then
        resp, err = core.json.decode(table.concat(response_body))
    end

    if err or not resp or type(resp) ~= "table" then
        return nil, err
    end

    return resp, nil
end


return _M
