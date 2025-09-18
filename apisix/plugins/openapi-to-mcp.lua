--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
local core        = require("apisix.core")
local upstream    = require("apisix.upstream")
local plugin      = require("apisix.plugin")
local ngx         = ngx
local pairs       = pairs
local str_format  = string.format

local schema = {
    type = "object",
    properties = {
        openapi_url = {
            description = "URL of the OpenAPI specification document",
            type = "string",
            minLength = 1,
        },
        base_url = {
            description = "Base URL of the external service",
            type = "string",
            minLength = 1,
        },
        headers = {
            description = "Headers to include in requests to the external service",
            type = "object",
            minProperties = 0,
            patternProperties = {
                ["^[^:]+$"] = {
                    oneOf = {
                        { type = "string" }
                    }
                }
            },
        },
    },
    required = { "openapi_url", "base_url" },
}

local attr_schema = {
    type = "object",
    properties = {
        port = {
            type = "integer",
            default = 3000,
            description = "The port where the MCP server is running",
        },
    },
}

local plugin_name = "openapi-to-mcp"

local _M = {
    version  = 0.1,
    priority = 503,
    name     = plugin_name,
    schema   = schema,
    attr_schema = attr_schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


function _M.init()
    local plugin_attr = plugin.plugin_attr(plugin_name)
    plugin_attr = plugin_attr and core.table.clone(plugin_attr) or {}
    local ok, err = core.schema.check(attr_schema, plugin_attr)
    if not ok then
        core.log.error("failed to check the plugin_attr[", plugin_name, "]", ": ", err)
        return
    end
end


function _M.access(conf, ctx)
    local plugin_attr = plugin.plugin_attr(plugin_name)

    local mcp_server_node = {
        host = "127.0.0.1",
        port = plugin_attr and plugin_attr.port or 3000,
        weight = 1,
        priority = 0
    }

    local up_conf = {
        name = "api7-mcp-server",
        type = "roundrobin",
        nodes = { mcp_server_node },
        scheme = "http",
    }

    local matched_route = ctx.matched_route
    up_conf.parent = matched_route
    local upstream_key = up_conf.type .. "#route_" .. matched_route.value.id .. "_openapi_to_mcp"

    ctx.var.upstream_scheme = "http"
    ctx.var.upstream_host = mcp_server_node.host
    ctx.var.upstream_port = mcp_server_node.port
    upstream.set(ctx, upstream_key, ctx.conf_version, up_conf)

    -- for message endpoint we just pass the request as is
    if ctx.var.method ~= "GET" then
        return
    end

    -- for sse endpoint, we need to rewrite the request to /sse with query parameters
    ngx.ctx.disable_proxy_buffering = true
    local query = str_format("base_url=%s&openapi_spec=%s&message_path=%s",
        core.utils.uri_safe_encode(conf.base_url),
        core.utils.uri_safe_encode(conf.openapi_url),
        core.utils.uri_safe_encode(ctx.curr_req_matched._path)
    )
    for key, value in pairs(conf.headers) do
        local resolved_value, err = core.utils.resolve_var(value, ctx.var)
        if err then
            core.log.warn("failed to resolve variable for header, key: ", key,
                                ", value: ", value, ", error: ", err)
            resolved_value = value
        end
        query = str_format("%s&headers.%s=%s", query,
                        core.utils.uri_safe_encode(key),
                        core.utils.uri_safe_encode(resolved_value))
    end

    ctx.var.upstream_uri = "/sse?" .. query
end


return _M
