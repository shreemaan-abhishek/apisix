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
local base_prometheus = require("prometheus")
local tonumber        = tonumber
local core      = require("apisix.core")
local plugin    = require("apisix.plugin")
local ipairs    = ipairs
local pairs     = pairs
local ngx       = ngx
local re_gmatch = ngx.re.gmatch
local ffi       = require("ffi")
local C         = ffi.C
local pcall = pcall
local select = select
local type = type
local basic_prometheus
local basic_prometheus_bkp
local advanced_prometheus
local advanced_prometheus_bkp
local router = require("apisix.router")
local get_routes = router.http_routes
local get_ssls   = router.ssls
local get_services = require("apisix.http.service").services
local get_consumers = require("apisix.consumer").consumers
local get_upstreams = require("apisix.upstream").upstreams
local clear_tab = core.table.clear
local get_stream_routes = router.stream_routes
local get_protos = require("apisix.plugins.grpc-transcode.proto").protos
local service_fetch = require("apisix.http.service").get
local latency_details = require("apisix.utils.log-util").latency_details_in_ms
local xrpc = require("apisix.stream.xrpc")
local timeout_err = "timeout"

local shdict_name = "config"
if ngx.config.subsystem == "stream" then
    shdict_name = shdict_name .. "-stream"
end
local config_dict = ngx.shared[shdict_name]

local status_dict = ngx.shared["prometheus-status"]
if not status_dict then
    error('shared dict prometheus-status not defined')
end
local metric_dict = ngx.shared["prometheus-metrics-advanced"]
if not metric_dict then
    error('shared dict prometheus-metrics-advanced not defined')
end

local next = next


local ngx_capture
if ngx.config.subsystem == "http" then
    ngx_capture = ngx.location.capture
end


local plugin_name = "prometheus"
local default_export_uri = "/apisix/prometheus/metrics"
-- Default set of latency buckets, 1ms to 60s:
local DEFAULT_BUCKETS = {1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 30000, 60000}

local metrics = {}

local inner_tab_arr = {}

local function gen_arr(...)
    clear_tab(inner_tab_arr)
    for i = 1, select('#', ...) do
        inner_tab_arr[i] = select(i, ...)
    end

    return inner_tab_arr
end

local extra_labels_tbl = {}

local function extra_labels(name, ctx)
    clear_tab(extra_labels_tbl)

    local attr = plugin.plugin_attr("prometheus")
    local metrics = attr.metrics

    if metrics and metrics[name] and metrics[name].extra_labels then
        local labels = metrics[name].extra_labels
        for _, kv in ipairs(labels) do
            local val, v = next(kv)
            if ctx then
                val = ctx.var[v:sub(2)]
                if val == nil then
                    val = ""
                end
            end
            core.table.insert(extra_labels_tbl, val)
        end
    end

    return extra_labels_tbl
end


local _M = {
    disabling = false,
}


local function init_stream_metrics()
    metrics.stream_connection_total = advanced_prometheus:counter("stream_connection_total",
        "Total number of connections handled per stream route in APISIX",
        {"route"})

    xrpc.init_metrics(advanced_prometheus)
end

local metric_label_map = {
    connections = {"state", "gateway_group_id", "instance_id"},
    requests = {"gateway_group_id", "instance_id"},
    etcd_reachable = {"gateway_group_id", "instance_id"},
    prometheus_disable = {"gateway_group_id", "instance_id"},
    node_info = {"hostname", "gateway_group_id", "instance_id"},
    etcd_modify_indexes = {"key", "gateway_group_id", "instance_id"},
    shared_dict_capacity_bytes = {"name", "gateway_group_id", "instance_id"},
    shared_dict_free_space_bytes = {"name", "gateway_group_id", "instance_id"},
    status = {"code", "route", "route_id", "matched_uri", "matched_host",
          "service", "service_id", "consumer", "node",
          "gateway_group_id", "instance_id", "api_product_id",
          "request_type", "request_llm_model", "llm_model",
         },
    latency = {"type", "route", "route_id", "service", "service_id", "consumer",
           "node", "gateway_group_id", "instance_id", "api_product_id",
           "request_type", "request_llm_model", "llm_model",
          },
    bandwidth = {"type", "route", "route_id", "service", "service_id", "consumer",
            "node", "gateway_group_id", "instance_id", "api_product_id",
            "request_type", "request_llm_model", "llm_model",
          },
    llm_latency = {"route", "route_id", "service", "service_id", "consumer",
             "node", "gateway_group_id", "instance_id", "api_product_id",
             "request_type", "request_llm_model", "llm_model",
            },
    llm_prompt_tokens = {"route", "route_id", "matched_uri", "matched_host",
              "service", "service_id", "consumer", "node",
              "gateway_group_id", "instance_id", "api_product_id",
              "request_type", "request_llm_model", "llm_model",
              },
    llm_completion_tokens = {"route", "route_id", "matched_uri", "matched_host",
              "service", "service_id", "consumer", "node",
              "gateway_group_id", "instance_id", "api_product_id",
              "request_type", "request_llm_model", "llm_model",
          },
    llm_active_connections = {"route", "route_id", "matched_uri", "matched_host",
              "service", "service_id", "consumer", "node",
              "gateway_group_id", "instance_id", "api_product_id",
              "request_type", "request_llm_model", "llm_model",
          },
}


local function append_tables(...)
    local t3 = {}
    for _, t2 in ipairs({...}) do
        for _, v in ipairs(t2) do
            core.table.insert(t3, v)
        end
    end
    return t3
 end


function _M.http_init(prometheus_enabled_in_stream)
    -- todo: support hot reload, we may need to update the lua-prometheus
    -- library
    if ngx.get_phase() ~= "init" and ngx.get_phase() ~= "init_worker"  then
        if basic_prometheus_bkp then
            basic_prometheus = basic_prometheus_bkp
        end
        if advanced_prometheus_bkp then
            advanced_prometheus = advanced_prometheus_bkp
        end
        return
    end

    clear_tab(metrics)

    -- Newly added metrics should follow the naming best practices described in
    -- https://prometheus.io/docs/practices/naming/#metric-names
    -- For example,
    -- 1. Add unit as the suffix
    -- 2. Add `_total` as the suffix if the metric type is counter
    -- 3. Use base unit
    -- We keep the old metric names for the compatibility.

    -- across all services
    local metric_prefix = "apisix_"
    local attr = plugin.plugin_attr("prometheus")
    if attr and attr.metric_prefix then
        metric_prefix = attr.metric_prefix
    end

    local status_exptime = core.table.try_read_attr(attr, "metrics", "http_status", "expire")
    local latency_exptime = core.table.try_read_attr(attr, "metrics", "http_latency", "expire")
    local bandwidth_exptime = core.table.try_read_attr(attr, "metrics", "bandwidth", "expire")
    local llm_latency_exptime = core.table.try_read_attr(attr, "metrics", "llm_latency", "expire")
    local llm_prompt_tokens_exptime = core.table.try_read_attr(attr, "metrics",
                                                            "llm_prompt_tokens", "expire")
    local llm_completion_tokens_exptime = core.table.try_read_attr(attr, "metrics",
                                                            "llm_completion_tokens", "expire")
    local llm_active_connections_exptime = core.table.try_read_attr(attr, "metrics",
                                                            "llm_active_connections", "expire")

    basic_prometheus = base_prometheus.init("prometheus-metrics-basic", metric_prefix)
    advanced_prometheus = base_prometheus.init("prometheus-metrics-advanced", metric_prefix)

    metrics.connections = basic_prometheus:gauge("nginx_http_current_connections",
            "Number of HTTP connections",
            metric_label_map.connections)

    metrics.requests = basic_prometheus:gauge("http_requests_total",
            "The total number of client requests since APISIX started",
            metric_label_map.requests)

    metrics.etcd_reachable = basic_prometheus:gauge("etcd_reachable",
            "Config server etcd reachable from APISIX, 0 is unreachable",
            metric_label_map.etcd_reachable)

    metrics.prometheus_disable = basic_prometheus:gauge("prometheus_disable",
            "Disable prometheus metrics collection, 1 is disabled, 0 is enabled",
            metric_label_map.prometheus_disable)

    metrics.node_info = basic_prometheus:gauge("node_info",
            "Info of APISIX node",
            metric_label_map.node_info)

    metrics.etcd_modify_indexes = basic_prometheus:gauge("etcd_modify_indexes",
            "Etcd modify index for APISIX keys",
            metric_label_map.etcd_modify_indexes)

    metrics.shared_dict_capacity_bytes = basic_prometheus:gauge("shared_dict_capacity_bytes",
            "The capacity of each nginx shared DICT since APISIX start",
            metric_label_map.shared_dict_capacity_bytes)

    metrics.shared_dict_free_space_bytes = basic_prometheus:gauge("shared_dict_free_space_bytes",
            "The free space of each nginx shared DICT since APISIX start",
            metric_label_map.shared_dict_free_space_bytes)

    -- per service

    -- The consumer label indicates the name of consumer corresponds to the
    -- request to the route/service, it will be an empty string if there is
    -- no consumer in request.
    metrics.status = advanced_prometheus:counter("http_status",
            "HTTP status codes per service in APISIX",
            append_tables(metric_label_map.status,
            extra_labels("http_status")), status_exptime)

    local buckets = DEFAULT_BUCKETS
    if attr and attr.default_buckets then
        buckets = attr.default_buckets
    end
    metrics.latency = advanced_prometheus:histogram("http_latency",
        "HTTP request latency in milliseconds per service in APISIX",
        append_tables(metric_label_map.latency,
        extra_labels("http_latency")),
        buckets, latency_exptime)

    metrics.bandwidth = advanced_prometheus:counter("bandwidth",
            "Total bandwidth in bytes consumed per service in APISIX",
            append_tables(metric_label_map.bandwidth,
            extra_labels("bandwidth")), bandwidth_exptime)

    local llm_latency_buckets = DEFAULT_BUCKETS
    if attr and attr.llm_latency_buckets then
        llm_latency_buckets = attr.llm_latency_buckets
    end
    metrics.llm_latency = advanced_prometheus:histogram("llm_latency",
        "LLM request latency in milliseconds",
        append_tables(metric_label_map.llm_latency,
        extra_labels("llm_latency")),
        llm_latency_buckets, llm_latency_exptime)

    metrics.llm_prompt_tokens = advanced_prometheus:counter("llm_prompt_tokens",
            "LLM service consumed prompt tokens",
            append_tables(metric_label_map.llm_prompt_tokens,
            extra_labels("llm_prompt_tokens")), llm_prompt_tokens_exptime)

    metrics.llm_completion_tokens = advanced_prometheus:counter("llm_completion_tokens",
            "LLM service consumed completion tokens",
            append_tables(metric_label_map.llm_completion_tokens,
            extra_labels("llm_completion_tokens")), llm_completion_tokens_exptime)

    metrics.llm_active_connections = advanced_prometheus:gauge("llm_active_connections",
            "Number of active connections to LLM service",
            append_tables(metric_label_map.llm_active_connections,
            extra_labels("llm_active_connections")), llm_active_connections_exptime)

    if prometheus_enabled_in_stream then
        init_stream_metrics()
    end
end


function _M.stream_init()
    if ngx.get_phase() ~= "init" and ngx.get_phase() ~= "init_worker"  then
        return
    end

    if not pcall(function() return C.ngx_meta_lua_ffi_shdict_udata_to_zone end) then
        core.log.error("need to build APISIX-Base to support L4 metrics")
        return
    end

    clear_tab(metrics)

    local metric_prefix = "apisix_"
    local attr = plugin.plugin_attr("prometheus")
    if attr and attr.metric_prefix then
        metric_prefix = attr.metric_prefix
    end

    basic_prometheus = base_prometheus.init("prometheus-metrics-basic", metric_prefix)
    advanced_prometheus = base_prometheus.init("prometheus-metrics-advanced", metric_prefix)
    init_stream_metrics()
end


local function get_gateway_group_id()
    local gateway_group_id, err = config_dict:get("gateway_group_id")
    if not gateway_group_id then
        core.log.warn("failed to get gateway_group_id: ", err)
        return ""
    end
    return gateway_group_id
end


local function get_enabled_label_values_for_metric(metric_name, disabled_label_metric_map, ...)
    local label_values = { ... }
    local metric_labels = metric_label_map[metric_name]

    if not metric_labels then
        return { ... }
    end

    local disabled_labels = disabled_label_metric_map[metric_name] or {}

    -- Iterate through the label values and update as needed.
    -- There is 1:1 mapping between metric_labels as keys and label_values as values.
    for i in ipairs(label_values) do
        local label_name = metric_labels[i]
        if label_name and disabled_labels[label_name] then
            label_values[i] = ""
        end
    end

    return label_values
end


local function get_disabled_label_metric_map()
    local metadata = plugin.plugin_metadata(plugin_name)
    core.log.info("metadata: ", core.json.delay_encode(metadata))
    local disabled_labels = (metadata and metadata.value and metadata.value.disabled_labels) or {}
    local disabled_label_metric_map = {}
    for metric_name, disabled_labels_arr in pairs(disabled_labels) do
        disabled_label_metric_map[metric_name] = {}
        for _, label in ipairs(disabled_labels_arr) do
            disabled_label_metric_map[metric_name][label] = true
        end
    end
    return disabled_label_metric_map
end


function _M.http_log(conf, ctx)
    local disabled_label_metric_map = get_disabled_label_metric_map()

    local vars = ctx.var

    local route_id = ""
    local route = ""
    local balancer_ip = ctx.balancer_ip or ""
    local service_id = ""
    local service = ""
    local consumer_name = ctx.consumer_name or ""
    local gateway_group_id = get_gateway_group_id()
    local instance_id = core.id.get()
    local api_product_id = ctx.api_product_id or ""

    local matched_route = ctx.matched_route and ctx.matched_route.value
    if matched_route then
        route = matched_route.id
        route_id = matched_route.id
        service = matched_route.service_id or ""
        service_id = matched_route.service_id or ""
        if conf.prefer_name == true then
            route = matched_route.name or route
            if service_id ~= "" then
                local fetched_service = service_fetch(service_id)
                service = fetched_service and fetched_service.value.name or service_id
            end
        end
    end

    local matched_uri = ""
    local matched_host = ""
    if ctx.curr_req_matched then
        matched_uri = ctx.curr_req_matched._path or ""
        matched_host = ctx.curr_req_matched._host or ""
    end

    metrics.status:inc(1,
        append_tables(get_enabled_label_values_for_metric("status", disabled_label_metric_map,
        vars.status, route, route_id, matched_uri, matched_host,
        service, service_id, consumer_name, balancer_ip, gateway_group_id,
        instance_id, api_product_id, vars.request_type, vars.request_llm_model, vars.llm_model),
        extra_labels("http_status", ctx)))

    local latency, upstream_latency, apisix_latency = latency_details(ctx)
    local latency_extra_label_values = extra_labels("http_latency", ctx)

    metrics.latency:observe(latency,
        append_tables(get_enabled_label_values_for_metric("latency", disabled_label_metric_map,
        "request", route, route_id, service, service_id, consumer_name,
        balancer_ip, gateway_group_id, instance_id, api_product_id,
        vars.request_type, vars.request_llm_model, vars.llm_model),
        latency_extra_label_values))

    if upstream_latency then
        metrics.latency:observe(upstream_latency,
            append_tables(get_enabled_label_values_for_metric("latency", disabled_label_metric_map,
            "upstream", route, route_id, service, service_id, consumer_name,
            balancer_ip, gateway_group_id, instance_id, api_product_id,
            vars.request_type, vars.request_llm_model, vars.llm_model),
            latency_extra_label_values))
    end

    metrics.latency:observe(apisix_latency,
        append_tables(get_enabled_label_values_for_metric("latency", disabled_label_metric_map,
        "apisix", route, route_id, service, service_id, consumer_name,
        balancer_ip, gateway_group_id, instance_id, api_product_id,
        vars.request_type, vars.request_llm_model, vars.llm_model),
        latency_extra_label_values))

    local bandwidth_extra_label_values = extra_labels("bandwidth", ctx)

    metrics.bandwidth:inc(vars.request_length,
        append_tables(get_enabled_label_values_for_metric("bandwidth", disabled_label_metric_map,
        "ingress", route, route_id, service, service_id, consumer_name,
        balancer_ip, gateway_group_id, instance_id, api_product_id,
        vars.request_type, vars.request_llm_model, vars.llm_model),
        bandwidth_extra_label_values))

    metrics.bandwidth:inc(vars.bytes_sent,
        append_tables(get_enabled_label_values_for_metric("bandwidth", disabled_label_metric_map,
        "egress", route, route_id, service, service_id, consumer_name,
        balancer_ip, gateway_group_id, instance_id, api_product_id,
        vars.request_type, vars.request_llm_model, vars.llm_model),
        bandwidth_extra_label_values))

    local llm_time_to_first_token = vars.llm_time_to_first_token
    if llm_time_to_first_token ~= "" then
        metrics.llm_latency:observe(tonumber(llm_time_to_first_token),
            append_tables(get_enabled_label_values_for_metric("llm_latency",
                disabled_label_metric_map,
            route, route_id, service, service_id, consumer_name,
            balancer_ip, gateway_group_id, instance_id, api_product_id,
            vars.request_type, vars.request_llm_model, vars.llm_model),
            extra_labels("llm_latency", ctx)))
    end

    if vars.llm_prompt_tokens ~= "" then
        metrics.llm_prompt_tokens:inc(tonumber(vars.llm_prompt_tokens),
            append_tables(get_enabled_label_values_for_metric("llm_prompt_tokens",
            disabled_label_metric_map, route, route_id, matched_uri,
            matched_host, service, service_id, consumer_name, balancer_ip,
            gateway_group_id, instance_id, api_product_id,
            vars.request_type, vars.request_llm_model, vars.llm_model),
            extra_labels("llm_prompt_tokens", ctx)))
    end
    if vars.llm_completion_tokens ~= "" then
        metrics.llm_completion_tokens:inc(tonumber(vars.llm_completion_tokens),
            append_tables(get_enabled_label_values_for_metric("llm_completion_tokens",
            disabled_label_metric_map, route, route_id, matched_uri,
            matched_host, service, service_id, consumer_name, balancer_ip,
            gateway_group_id, instance_id, api_product_id,
            vars.request_type, vars.request_llm_model, vars.llm_model),
            extra_labels("llm_completion_tokens", ctx)))
    end
end


function _M.stream_log(conf, ctx)
    local route_id = ""
    local matched_route = ctx.matched_route and ctx.matched_route.value
    if matched_route then
        route_id = matched_route.id
        if conf.prefer_name == true then
            route_id = matched_route.name or route_id
        end
    end

    metrics.stream_connection_total:inc(1, gen_arr(route_id))
end


local ngx_status_items = {"active", "accepted", "handled", "total",
                         "reading", "writing", "waiting"}
local label_values = {}

local function nginx_status(gateway_group_id, instance_id)
    local res = ngx_capture("/apisix/nginx_status")
    if not res or res.status ~= 200 then
        core.log.error("failed to fetch Nginx status")
        return
    end

    -- Active connections: 2
    -- server accepts handled requests
    --   26 26 84
    -- Reading: 0 Writing: 1 Waiting: 1

    local iterator, err = re_gmatch(res.body, [[(\d+)]], "jmo")
    if not iterator then
        core.log.error("failed to re.gmatch Nginx status: ", err)
        return
    end

    for _, name in ipairs(ngx_status_items) do
        local val = iterator()
        if not val then
            break
        end

        if name == "total" then
            metrics.requests:set(val[0], {gateway_group_id, instance_id})
        else
            label_values = {name, gateway_group_id, instance_id,}
            metrics.connections:set(val[0], label_values)
        end
    end
end


local key_values = {}
local function set_modify_index(key, items, items_ver, global_max_index,
                                gateway_group_id, instance_id)
    clear_tab(key_values)
    local max_idx = 0
    if items_ver and items then
        for _, item in ipairs(items) do
            if type(item) == "table" then
                local modify_index = item.orig_modifiedIndex or item.modifiedIndex
                if modify_index > max_idx then
                    max_idx = modify_index
                end
            end
        end
    end

    key_values = {key, gateway_group_id, instance_id}
    metrics.etcd_modify_indexes:set(max_idx, key_values)


    global_max_index = max_idx > global_max_index and max_idx or global_max_index

    return global_max_index
end


local function etcd_modify_index(gateway_group_id, instance_id)
    clear_tab(key_values)
    local global_max_idx = 0

    -- routes
    local routes, routes_ver = get_routes()
    global_max_idx = set_modify_index("routes", routes, routes_ver, global_max_idx,
        gateway_group_id, instance_id)

    -- services
    local services, services_ver = get_services()
    global_max_idx = set_modify_index("services", services, services_ver, global_max_idx,
        gateway_group_id, instance_id)

    -- ssls
    local ssls, ssls_ver = get_ssls()
    global_max_idx = set_modify_index("ssls", ssls, ssls_ver, global_max_idx,
        gateway_group_id, instance_id)

    -- consumers
    local consumers, consumers_ver = get_consumers()
    global_max_idx = set_modify_index("consumers", consumers, consumers_ver, global_max_idx,
        gateway_group_id, instance_id)

    -- global_rules
    local global_rules = router.global_rules
    if global_rules then
        global_max_idx = set_modify_index("global_rules", global_rules.values,
            global_rules.conf_version, global_max_idx, gateway_group_id, instance_id)

        -- prev_index
        key_values = {"prev_index", gateway_group_id, instance_id}
        metrics.etcd_modify_indexes:set(global_rules.prev_index, key_values)

    else
        global_max_idx = set_modify_index("global_rules", nil, nil, global_max_idx,
            gateway_group_id, instance_id)
    end

    -- upstreams
    local upstreams, upstreams_ver = get_upstreams()
    global_max_idx = set_modify_index("upstreams", upstreams, upstreams_ver, global_max_idx,
        gateway_group_id, instance_id)

    -- stream_routes
    local stream_routes, stream_routes_ver = get_stream_routes()
    global_max_idx = set_modify_index("stream_routes", stream_routes,
        stream_routes_ver, global_max_idx, gateway_group_id, instance_id)

    -- proto
    local protos, protos_ver = get_protos()
    global_max_idx = set_modify_index("protos", protos, protos_ver, global_max_idx,
        gateway_group_id, instance_id)

    -- global max
    key_values = {"max_modify_index", gateway_group_id, instance_id}
    metrics.etcd_modify_indexes:set(global_max_idx, key_values)

end


local function shared_dict_status(gateway_group_id, instance_id)
    for shared_dict_name, shared_dict in pairs(ngx.shared) do
        local labels = {shared_dict_name, gateway_group_id, instance_id}
        metrics.shared_dict_capacity_bytes:set(shared_dict:capacity(), labels)
        metrics.shared_dict_free_space_bytes:set(shared_dict:free_space(), labels)
    end
end


local function collect_regular_metrics(stream_only)
    if not basic_prometheus or not advanced_prometheus or not metrics then
        return
    end

    local gateway_group_id = get_gateway_group_id()
    local instance_id = core.id.get()

    -- collect ngx.shared.DICT status
    shared_dict_status(gateway_group_id, instance_id)

    local config = core.config.new()

    -- we can't get etcd index in metric server if only stream subsystem is enabled
    if config.type == "etcd" and not stream_only then
        -- etcd modify index
        etcd_modify_index(gateway_group_id, instance_id)

        local version, err = config:server_version()
        if version then
            metrics.etcd_reachable:set(1, {gateway_group_id, instance_id,})

        else
            metrics.etcd_reachable:set(0, {gateway_group_id, instance_id,})
            core.log.error("prometheus: failed to reach config server while ",
                           "processing metrics endpoint: ", err)
        end

        -- Because request any key from etcd will return the "X-Etcd-Index".
        -- A non-existed key is preferred because it doesn't return too much data.
        -- So use phantom key to get etcd index.
        local res, _ = config:getkey("/phantomkey")
        if res and res.headers then
            clear_tab(key_values)
            -- global max
            key_values = {"x_etcd_index", gateway_group_id, instance_id}
            metrics.etcd_modify_indexes:set(res.headers["X-Etcd-Index"], key_values)
        end
    end

    if status_dict:get("disabled") then
        metrics.prometheus_disable:set(1, {gateway_group_id, instance_id})
    else
        metrics.prometheus_disable:set(0, {gateway_group_id, instance_id})
    end
end


local function collect_api_specific_metrics()
    local gateway_group_id = get_gateway_group_id()
    local instance_id = core.id.get()
    -- across all services
    nginx_status(gateway_group_id, instance_id)

    local vars = ngx.var or {}
    local hostname = vars.hostname or ""
    metrics.node_info:set(1, gen_arr(hostname, gateway_group_id, instance_id))
end

local function timer(timeout, id)
    ngx.sleep(timeout)
    return timeout_err
end

local prometheus_advanced_metric_data = function ()
    if not advanced_prometheus then
        return {}
    end
    return advanced_prometheus:metric_data()
end

local combined_prometheus = {}

setmetatable(combined_prometheus, {
    __index = function(_, key)
        return advanced_prometheus[key]
    end
})

function combined_prometheus.metric_data()
    local attr = plugin.plugin_attr(plugin_name)
    local timeout = attr and attr.fetch_metric_timeout or 5
    local thread_timer, err = ngx.thread.spawn(timer, timeout)
    if not thread_timer then
        core.log.error("failed to spawn thread f: ", err)
        return {}
    end
    local fetch_metrics_thread, err = ngx.thread.spawn(prometheus_advanced_metric_data)
    if not fetch_metrics_thread then
        core.log.error("failed to spawn thread g: ", err)
        return {}
    end
    local ok, metric_data = ngx.thread.wait(fetch_metrics_thread, thread_timer)
    if not ok then
        core.log.error("failed to wait")
        return {}
    end

    if metric_data == timeout_err then
        local ok , err = ngx.thread.kill(fetch_metrics_thread)
        if not ok then
            core.log.warn("failed to kill advanced_metric process thread: ", err)
        end
        core.log.warn("fetch advanced prometheus metrics timeout")
        metric_data = {}
    end

    if basic_prometheus then
        local basic_metrics = basic_prometheus:metric_data()
        for _, v in ipairs(basic_metrics) do
            core.table.insert(metric_data, v)
        end
    end
    return metric_data
end

local function collect(ctx, stream_only)
    collect_api_specific_metrics()
    collect_regular_metrics(stream_only)

    core.response.set_header("content_type", "text/plain")
    return 200, core.table.concat(combined_prometheus:metric_data())
end

_M.collect = collect
_M.collect_regular_metrics = collect_regular_metrics
_M.collect_api_specific_metrics = collect_api_specific_metrics

local function get_api(called_by_api_router)
    local export_uri = default_export_uri
    local attr = plugin.plugin_attr(plugin_name)
    if attr and attr.export_uri then
        export_uri = attr.export_uri
    end

    local api = {
        methods = {"GET"},
        uri = export_uri,
        handler = collect
    }

    if not called_by_api_router then
        return api
    end

    if attr.enable_export_server then
        return {}
    end

    return {api}
end
_M.get_api = get_api


function _M.export_metrics(stream_only)
    if not basic_prometheus and not advanced_prometheus then
        core.response.exit(200, "{}")
    end
    local api = get_api(false)
    local uri = ngx.var.uri
    local method = ngx.req.get_method()

    if uri == api.uri and method == api.methods[1] then
        local code, body = api.handler(nil, stream_only)
        if code or body then
            core.response.exit(code, body)
        end
    end

    return core.response.exit(404)
end


function _M.metric_data()
    return combined_prometheus:metric_data()
end


local function inc_llm_active_connections(ctx, value)
    local attr = plugin.plugin_attr("prometheus")
    if attr and attr.allow_degradation then
        if status_dict:get("disabled") then
            core.log.info("prometheus plugin is disabled")
            return
        end
    end
    local disabled_label_metric_map = get_disabled_label_metric_map()

    local vars = ctx.var

    local route_id = ""
    local route_name = ""
    local balancer_ip = ctx.balancer_ip or ""
    local service_id = ""
    local service_name = ""
    local consumer_name = ctx.consumer_name or ""
    local gateway_group_id = get_gateway_group_id()
    local instance_id = core.id.get()
    local api_product_id = ctx.api_product_id or ""

    local matched_route = ctx.matched_route and ctx.matched_route.value
    if matched_route then
        route_id = matched_route.id
        route_name = matched_route.name or ""
        service_id = matched_route.service_id or ""
        if service_id ~= "" then
            local fetched_service = service_fetch(service_id)
            service_name = fetched_service and fetched_service.value.name or ""
        end
    end

    local matched_uri = ""
    local matched_host = ""
    if ctx.curr_req_matched then
        matched_uri = ctx.curr_req_matched._path or ""
        matched_host = ctx.curr_req_matched._host or ""
    end

    metrics.llm_active_connections:inc(value,
        append_tables(get_enabled_label_values_for_metric("llm_active_connections",
        disabled_label_metric_map, route_name, route_id, matched_uri,
        matched_host, service_name, service_id, consumer_name, balancer_ip,
        gateway_group_id, instance_id, api_product_id,
        vars.request_type, vars.request_llm_model, vars.llm_model),
        extra_labels("llm_active_connections", ctx)))
end


function _M.inc_llm_active_connections(ctx)
    inc_llm_active_connections(ctx, 1)
end


function _M.dec_llm_active_connections(ctx)
    inc_llm_active_connections(ctx, -1)
end


function _M.get_prometheus()
    if not basic_prometheus or not advanced_prometheus then
        return nil
    end
    return combined_prometheus
end

function _M.destroy()
    if basic_prometheus ~= nil then
        basic_prometheus_bkp = core.table.deepcopy(basic_prometheus)
        basic_prometheus = nil
    end

    if advanced_prometheus ~= nil then
        advanced_prometheus_bkp = core.table.deepcopy(advanced_prometheus)
        advanced_prometheus = nil
    end
    status_dict:flush_all()
    status_dict:flush_expired()
end

function _M.disable_on_memory_full(self)
    local attr = plugin.plugin_attr("prometheus")
    if not attr or not attr.allow_degradation then
        return
    end
    -- Currently only one value is used for pausing prometheus
    -- TODO: Support degradation_pause_steps to support multiple subsequent pause intervals
    local timeout = (attr and attr.degradation_pause_steps and attr.degradation_pause_steps[1])
                     or 60
    ngx.timer.every(1, function ()
        if self.disabling then
            return
        end
        self.disabling = true
        if status_dict:get("memory_full") then
            core.log.error("Shared dictionary used for prometheus metrics is full ",
            "please increase the size of the shared dict. Disabling for ", timeout, " seconds")
            status_dict:set("disabled", true)
            -- wait for all pending http_log phases to be done
            ngx.sleep(1)
            metric_dict:flush_all()
            metric_dict:flush_expired()
            status_dict:set("memory_full", false)
            ngx.sleep(timeout)
            status_dict:set("disabled", false)
            core.log.info("Prometheus metrics collection is enabled again")
        end
        self.disabling = false
    end)
end

return _M
