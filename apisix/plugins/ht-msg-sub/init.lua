local require = require
local type = type
local pcall = pcall
local ipairs = ipairs
local ngx = ngx
local ngx_now = ngx.now
local pairs = pairs
local tonumber = tonumber
local ngx_re = require("ngx.re")
local uuid = require('resty.jit-uuid')
local core = require("apisix.core")
local topic = require("apisix.utils.topic")
local misc_utils = require("apisix.utils.misc")
local ms1975 = require("apisix.plugins.ht-msg-sub.ms1975")
local log = require("apisix.plugins.ht-msg-sub.log")
local push_gateway = require("apisix.plugins.ht-ws-msg-pub.push_gateway")

local schema = {
    type = "object",
    properties = {
        action = {
            type = "string",
            enum = {"sub_put", "sub_add", "sub_delete", "register", "disconnect", "proxy"},
        },
        headers = {
            type = "object",
            properties = {
                add = {
                    type = "object",
                    properties = {
                        ["^[^:]+$"] = {
                            type = "string",
                        },
                    },
                },
                set = {
                    type = "object",
                    properties = {
                        ["^[^:]+$"] = {
                            type = "string",
                        },
                    },
                },
                remove = {
                    type = "array",
                    minItems = 1,
                    items = {
                        type = "string",
                        -- "Referer"
                        pattern = "^[^:]+$"
                    }
                },
            },
        },
        upstream = {
            type = "object",
            properties = {
                type = {
                    description = "algorithms of load balancing",
                    type = "string",
                    default = "roundrobin",
                },
                nodes = {
                    type = "array",
                    items = {
                        type = "object",
                        properties = {
                            host = {
                                type = "string",
                                pattern = "^\\*?[0-9a-zA-Z-._\\[\\]:]+$",
                            },
                            port = {
                                description = "port of node",
                                type = "integer",
                                minimum = 1,
                            },
                            weight = {
                                description = "weight of node",
                                type = "integer",
                                minimum = 0,
                            },
                            priority = {
                                description = "priority of node",
                                type = "integer",
                                default = 0,
                            },
                            metadata = {
                                description = "metadata of node",
                                type = "object",
                            }
                        },
                        required = {"host", "port", "weight"},
                    },
                },
                timeout = {
                    type = "object",
                    properties = {
                        connect = {type = "number", exclusiveMinimum = 0},
                        send = {type = "number", exclusiveMinimum = 0},
                        read = {type = "number", exclusiveMinimum = 0},
                    },
                    required = {"connect", "send", "read"},
                },
                keepalive_pool = {
                    type = "object",
                    properties = {
                        size = {
                            type = "integer",
                            default = 320,
                            minimum = 1,
                        },
                        idle_timeout = {
                            type = "number",
                            default = 60,
                            minimum = 0,
                        },
                        requests = {
                            type = "integer",
                            default = 1000,
                            minimum = 1,
                        },
                    },
                },
                hash_on = {
                    type = "string",
                    default = "vars",
                    enum = {
                      "vars",
                      "header",
                      "cookie",
                      "consumer",
                      "vars_combinations",
                    },
                },
                key = {
                    description = "the key of chash for dynamic load balancing",
                    type = "string",
                },
            }
        },
    },
    required = {"action", "upstream"},
}

local plugin_name = "ht-msg-sub"

local _M = {
    version = 0.1,
    priority = 10,
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


local idx = 0
local function next_idx()
    idx = idx + 1
    if idx > 2^30 then
        idx = 1
    end

    return idx
end


local function patch_header(conf, header, ctx)
    header._uuid = (header.sid or "") .. "_" .. next_idx()

    if not header.msgId then
        header.msgId = header._uuid
    end

    header["gateway-metadata"] = {
        ["sid"] = header.sid,
        ["GatewayIP"] = misc_utils.get_server_ip(),
        ["SourceIP"] = core.request.get_remote_client_ip(ctx),
    }

    if conf and conf.headers then
        if conf.headers.add then
            for k, v in pairs(conf.headers.add) do
                if not header[k] then
                    header[k] = v
                end
            end
        end

        if conf.headers.set then
            for k, v in pairs(conf.headers.set) do
                header[k] = v
            end
        end

        if conf.headers.remove then
            for _, k in ipairs(conf.headers.remove) do
                header[k] = nil
            end
        end
    end

    return header
end


local function get_header(conf, ctx)
    if ctx.header then
        return patch_header(conf, ctx.header, ctx)
    end

    local header = core.request.headers()
    if not header then
        header = {}
    end

    return patch_header(conf, header, ctx)
end


local function get_uri(ctx)
    if ctx.var and ctx.var.uri then
        return ctx.var.uri
    end

    return ctx.uri
end


local function get_body(ctx)
    if ctx.body then
        return ctx.body
    end

    local body = core.request.get_body()

    if not body then
        body = {}
    end

    return body
end


local function send_to_ms1975(ctx, conf, uri, header, body)
    local resp_body = {
        msgId = header.msgId,
    }

    -- request to the ms1975 upstream
    local up, err = ms1975:new()
    if not up then
        core.log.error("failed to create ms1975 upstream: ", err)
        resp_body.code = "5003"
        resp_body.message = "failed to create ms1975 upstream"

        return false, 500, resp_body
    end

    if not ctx.upstream_key then
        ctx.upstream_conf = conf.upstream
        ctx.upstream_version = ctx.conf_version
        ctx.upstream_key = ctx.matched_route.value.id
    end

    local ok, err = up:connect(ctx)
    if not ok then
        core.log.error("failed to connect to upstream: ", err)

        local ok, err = up:retry_connect(ctx)
        if not ok then
            core.log.error("failed to restry connect to upstream: ", err)

            resp_body.code = "5021"
            resp_body.message = "failed to connect to upstream"

            return false, 502, resp_body
        end
    end

    local resp, err = up:to_upstream(uri, header, body)
    if err then
        core.log.error("failed to request upstream, resp: ",
            core.json.delay_encode(resp, true), ", error: ", err)

        if err == "timeout" then
            local ok, err = up:retry_connect(ctx)
            if not ok then
                core.log.error("failed to restry connect to upstream: ", err)
                resp_body.code = "5022"
                resp_body.message = "failed to request upstream"

                return false, 502, resp_body
            end
        end

        resp, err = up:to_upstream(uri, header, body)
        if err then
            core.log.error("failed to request upstream again, resp: ",
                core.json.delay_encode(resp, true), ", error: ", err)
            resp_body.code = "5023"
            resp_body.message = "failed to request upstream"

            return false, 502, resp_body
        end
    end

    if not resp or not resp.body then
        core.log.error("failed to request upstream, resp: ", core.json.delay_encode(resp, true))
        resp_body.code = "5024"
        resp_body.message = "failed to request upstream"

        return false, 502, resp_body
    end

    up:setkeepalive(conf.keepalive_timeout, conf.keepalive_size)

    if resp.body.code ~= "0" then
        core.log.error("failed to request upstream, resp: ",
            core.json.delay_encode(resp), ", error: ", err)

        local _, code = pcall(tonumber, resp.body.code)
        if not code then
            code = 0
        end

        -- if upstream return error code is 1000 ~ 1999,
        -- return error to client and do not save sid topic relation
        if code >= 1000 and code <= 1999 then
            return false, resp.status, resp.body, resp.header
        end

        -- if upstream return error code is 2000 ~ 2999,
        -- return 401 to client and close connection
        if code >= 2000 and code <= 2999 then
            return false, 401, resp.body, resp.header
        end
    end

    return true, resp.status, resp.body, resp.header
end


local function build_sid_topic_relation(conf, header, body)
    core.log.info("building sid topic relation, action: ", conf.action,
        ", sid: ", header.sid, ", topics: ", core.json.delay_encode(body.topics, true))
    if conf.action == "sub_put" then
        topic.sub_put(header.sid, body.topics)
    elseif conf.action == "sub_add" then
        topic.sub_add(header.sid, body.topics)
    elseif conf.action == "sub_delete" then
        topic.sub_delete(header.sid, body.topics)

        -- check and sync delete topic to push gateway
        local removed_topics = topic.get_removed_topics(body.topics)
        body.topics = removed_topics
    elseif conf.action == "register" then
        topic.sub_add(header.sid, body.topics)
    elseif conf.action == "disconnect" then
        local subcribed = topic.get_topics_by_sid(header.sid)
        core.log.info("disconnect sid: ", header.sid,
            ", subcribed topics: ", core.json.delay_encode(subcribed))

        local subcribed_topics = subcribed and core.table.clone(subcribed)
        topic.disconnect(header.sid, subcribed)

        local removed_topics = topic.get_removed_topics(subcribed_topics)
        body.topics = removed_topics
    end
end


local function notify_push_gateway(conf, header, body)
    local paction = conf.action

    -- no topic to handle
    if not body.topics or #body.topics == 0 then
        return
    end

    -- if topics is not empty
    -- disconnect action is sub_delete action for push gateway
    if paction == "disconnect" then
        paction = "sub_delete"
    end

    if paction == "sub_put" or paction == "register" then
         -- sub_put for push gateway can't trigger by client request
        paction = "sub_add"
    end

    push_gateway.notify(paction, header.msgId, body.topics)
end


function _M.access(conf, ctx)
    local header = get_header(conf, ctx)
    local uri = get_uri(ctx)
    local body = get_body(ctx)

    local resp_body = {
        msgId = header.msgId,
    }

    if type(body) ~= "table" then
        body = core.json.decode(body)
        if type(body) ~= "table" then
            body = {}
        end
    end

    if type(body.topics) ~= "table" and (conf.action == "sub_put" or
            conf.action == "sub_add" or conf.action == "sub_delete") then
        resp_body.code = "4002"
        resp_body.message = "invalid body"

        return 400, resp_body
    end

    if conf.action == "register" then
        body.topics = type(body.topics) == "table" and body.topics or {}
        local conn_topic = "sig_" .. header.sid
        core.table.insert(body.topics, conn_topic)
    end

    local up_conf = conf.upstream
    local keepalive_pool = up_conf and up_conf.keepalive_pool or nil
    conf.keepalive_timeout = keepalive_pool and keepalive_pool.idle_timeout or 60
    conf.keepalive_size = keepalive_pool and keepalive_pool.size or 320

    local now_time = ngx_now()

    local res, status, resp_body, resp_header = send_to_ms1975(ctx, conf, uri, header, body)

    ctx.var.upstream_response_time = ngx_now() - now_time

    -- if failed to request upstream or is proxy action, return directly
    if not res or conf.action == "proxy" then
        if ctx.is_ws then
            log.sub_log({
                msgId = header.msgId,
                action = conf.action,
                topics = body.topics,
                status = status,
            })
        end

        return status, resp_body
    end

    -- check respose topics
    if  (conf.action == "sub_put" or conf.action == "sub_add" or
            conf.action == "sub_delete") then
        if (conf.action == "sub_add" or conf.action == "sub_delete") and
            (not resp_header or not resp_header.topics) then
            resp_body.code = "4003"
            resp_body.message = "invalid request"

            return 400, resp_body
        end

        local topics = ngx_re.split(resp_header.topics, ",")
        if (conf.action == "sub_add" or conf.action == "sub_delete") and
            (not topics or #topics == 0 or (#topics == 1 and topics[1] == "")) then
            resp_body.code = "4004"
            resp_body.message = "invalid request"

            return 400, resp_body
        end

        -- replace topics with response topics
        body.topics = topics
    end

    -- build relation between sid (client connection) and topics
    build_sid_topic_relation(conf, header, body)

    -- sync topics to push gateway
    notify_push_gateway(conf, header, body)

    -- add sid to response body
    if conf.action == "register" then
        resp_body.resultData = resp_body.resultData or {}
        if type(resp_body.resultData) ~= "table" then
            resp_body.resultData = { origin = resp_body.resultData }
        end
        resp_body.resultData.sid = header.sid
    end

    if ctx.is_ws then
        log.sub_log({
            msgId = header.msgId,
            action = conf.action,
            topics = body.topics,
            status = 200,
        })
    end

    return 200, resp_body
end


function _M.init()
    uuid.seed()
    log.init()
end


return _M
