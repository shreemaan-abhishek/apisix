local require = require
local ngx = ngx
local wait = ngx.thread.wait
local thread_spawn = ngx.thread.spawn
local thread_kill = ngx.thread.kill
local type = type
local core = require("apisix.core")
local plugin = require("apisix.plugin")
local plugin_config = require("apisix.plugin_config")
local timers = require("apisix.timers")
local pkg_prefix = "apisix.plugins.ht-ws-msg-pub."
local websocket = require(pkg_prefix .. "websocket")
local push_gateway = require(pkg_prefix .. "push_gateway")
local downstream = require(pkg_prefix .. "downstream")
local subrouter = require(pkg_prefix .. "subrouter_http_uri")
local subplugin = require(pkg_prefix .. "subplugin")
local log = require(pkg_prefix .. "log")
local metrics = require(pkg_prefix .. "metrics")

local schema = {
    type = "object",
    properties = {
        disconnect_notify_urls = {
            type = "array",
            items = {
                type = "string",
            },
            description = "urls to notify when client disconnects"
        },
        apisix_ts_disabled = {
            type = "boolean",
            description = "whether to disable apisix_ts timestamp",
            default = false,
        },
    },
}

local metadata_schema = {
    type = "object",
    properties = {
        api7_push_gateway_addrs = {
            type = "array",
            items = {
                type = "string",
            },
            description = "api7 push gateway websocket addresses",
        },
    },
}

local attr_schema = {
    type = "object",
    properties = {
        heartbeat_interval = {
            type = "integer",
            description = "heartbeat interval in seconds",
            default = 60
        },
    },
}

local plugin_name = "ht-ws-msg-pub"

local _M = {
    version = 0.1,
    priority = 10,
    name = plugin_name,
    schema = schema,
    attr_schema = attr_schema,
    metadata_schema = metadata_schema
}


function _M.check_schema(conf, schema_type)
    if schema_type == core.schema.TYPE_METADATA then
        return core.schema.check(metadata_schema, conf)
    end

    return core.schema.check(schema, conf)
end


local function set_metrics_regularly()
    metrics.set_topic_count()
    metrics.set_queue_size()
    metrics.set_push_log_buffers_size()
end


function _M.init()
    log.init()

    local process = require("ngx.process")
    if process.type() ~= "worker" then
        return
    end

    metrics.init()
    push_gateway.init()

    timers.register_timer("plugin#ht-ws-msg-pub", set_metrics_regularly)
end


function _M.destroy()
    timers.unregister_timer("plugin#ht-ws-msg-pub")
end


function _M.access(conf, ctx)
    local ws_connection, err = websocket.apply_ws_connection()
    if not ws_connection then
        core.log.error("failed to initialize ws connection, err: ", err)
        core.response.exit(400)
        return
    end

    -- set connections when client connects
    metrics.set_connections()

    local client_ip = core.request.get_remote_client_ip(ctx)

    ws_connection.handler = (function (params)
        if type(params.header) ~= "table" then
            params.header = {}
        end

        local msg_id = params.header and params.header.msgId or ""
        if not params.uri or type(params.uri) ~= "string" then
            return true, {
                status = 400,
                body = {
                    code = "4001",
                    message = "400 Invalid URI",
                    msgId = msg_id,
                }
            }
        end

        local subroute = subrouter.match(params.uri, params.header, ctx.matched_route)
        core.log.info("hit the subroute: ", subroute ~= nil,
            ", subroute: ", core.json.delay_encode(subroute, true))

        if not subroute then
            return true, {
                status = 404,
                body = {
                    code = "4041",
                    message = "404 Route Not Found",
                    msgId = msg_id,
                }
            }
        end

        if subroute.value.plugin_config_id then
            local pconf = plugin_config.get(subroute.value.plugin_config_id)
            if not pconf then
                core.log.error("failed to fetch plugin config by ",
                    "id: ", subroute.value.plugin_config_id)
                return true, {
                    status = 503,
                    body = {
                        code = "5031",
                        message = "503 Service Unavailable",
                        msgId = msg_id,
                        subroute = subroute,
                    }
                }
            end

            subroute = plugin_config.merge(subroute, pconf)
        end

        params.header.sid = ws_connection.id
        local sub_ctx = params
        sub_ctx.var = subrouter.header_to_var(params.header)
        sub_ctx.var.uri = params.uri
        sub_ctx.var.remote_addr = client_ip
        sub_ctx.conf_version = subroute.modifiedIndex
        sub_ctx.matched_route = subroute
        sub_ctx.is_ws = true

        local plugins = plugin.filter(sub_ctx, subroute)

        local code, body = subplugin.run_plugin("rewrite", plugins, sub_ctx)
        if code or body then
            subplugin.run_plugin("log", plugins, sub_ctx)
            return true, {
                status = code,
                body = body,
                subroute = subroute,
            }
        end

        code, body = subplugin.run_plugin("access", plugins, sub_ctx)

        subplugin.run_plugin("log", plugins, sub_ctx)

        if sub_ctx.var.upstream_response_time then
            local upstream_latency = sub_ctx.var.upstream_response_time * 1000
            metrics.observe_upstream_latency(ctx.matched_route.value.id,
                subroute.value.id, upstream_latency)
        end

        return true, {
            status = code,
            body = body,
            subroute = subroute,
        }
    end)

    local to_co, err = thread_spawn(downstream.to_downstream_thread, ctx, conf, ws_connection)
    if not to_co then
        core.log.error("failed to start `to downstream thread`: ", err)
        return
    end

    local from_co, err = thread_spawn(downstream.from_downstream_thread, ctx, conf, ws_connection)
    if not from_co then
        core.log.error("failed to start `from downstream thread`: ", err)
        return
    end

    local ok, res = wait(to_co, from_co)
    if not ok then
        core.log.error("failed to wait downstream threads: ", core.json.delay_encode(res, true))
    end

    -- kill threads
    thread_kill(to_co)
    thread_kill(from_co)

    -- release ws connection
    websocket.release_ws_connection(ws_connection)
    -- update connections when client disconnects
    metrics.set_connections()

    ngx.exit(0)
end


return _M
