local require = require
local ngx = ngx
local timer_at = ngx.timer.at
local type = type
local plugin = require("apisix.plugin")
local topic = require("apisix.utils.topic")
local misc_utils = require("apisix.utils.misc")
local log = require("apisix.plugins.ht-ws-msg-pub.log")
local websocket = require("apisix.plugins.ht-ws-msg-pub.websocket")

local exporter
if ngx.config.subsystem == "http" then
    exporter = require("apisix.plugins.prometheus.exporter")
end

local _M = {}
local metrics = {}


local function define_metric()
    if not exporter or not exporter.get_prometheus() then
        return
    end

    local metadata = plugin.plugin_metadata("ht-ws-msg-pub")
    if metadata and type(metadata.value.metrics_enabled) == "boolean" and
        not metadata.value.metrics_enabled then
        return
    end

    local prometheus = exporter.get_prometheus()

    metrics.ws_connections = prometheus:gauge(
        "ws_current_connections",
        "Number of Websocket connections",
        {"worker"})
    metrics.ws_pub_total = prometheus:counter(
        "ws_pub_total",
        "Total number of published messages",
        {"topic"})
    metrics.ws_latency = prometheus:histogram(
        "ws_latency",
        "Latency of Websocket requests",
        {"route", "subroute"},
        {0.001, 0.005, 0.01, 0.05,
                    0.1, 0.5, 1, 5, 10, 50})
    metrics.ws_upstream_latency = prometheus:histogram(
        "ws_upstream_latency",
        "Latency of Websocket upstream requests",
        {"route", "subroute"},
        {0.001, 0.005, 0.01, 0.05,
                    0.1, 0.5, 1, 5, 10, 50})
    metrics.ws_status = prometheus:counter(
        "ws_status",
        "Status of Websocket requests",
        {"route", "subroute", "status"})
    metrics.ws_topic_count = prometheus:gauge(
        "ws_topic_count",
        "Count of topics",
        {"worker"})
    metrics.ws_msg_queue_size = prometheus:gauge(
        "ws_msg_queue_size",
        "Total number of messages in queue",
        {"worker"})
    metrics.ws_received_push_total = prometheus:counter(
        "ws_received_push_total",
        "Total number of messages that received from push gateway",
        {"worker"})
    metrics.ws_push_log_buffers_size = prometheus:gauge(
        "ws_push_log_buffers_size",
        "The size of buffers for push log ",
        {"worker"})
end


function _M.init()
    timer_at(0, define_metric)
end


function _M.set_connections()
    if not metrics.ws_connections then
        return
    end

    local worker_uni_id = misc_utils.get_worker_uni_id()

    return metrics.ws_connections:set(websocket.count_connections(), {worker_uni_id})
end


function _M.incr_pub_total(topic)
    if not metrics.ws_pub_total then
        return
    end

    return metrics.ws_pub_total:inc(1, {topic})
end


function _M.incr_received_push_total()
    if not metrics.ws_received_push_total then
        return
    end

    local worker_uni_id = misc_utils.get_worker_uni_id()

    return metrics.ws_received_push_total:inc(1, {worker_uni_id})
end


function _M.observe_latency(route_id, subroute_id, latency)
    if not metrics.ws_latency then
        return
    end

    return metrics.ws_latency:observe(latency, {route_id, subroute_id})
end


function _M.observe_upstream_latency(route_id, subroute_id, latency)
    if not metrics.ws_upstream_latency then
        return
    end

    return metrics.ws_upstream_latency:observe(latency, {route_id, subroute_id})
end


function _M.incr_status(route_id, subroute_id, status)
    if not metrics.ws_status then
        return
    end

    return metrics.ws_status:inc(1, {route_id, subroute_id, status})
end


function _M.set_topic_count()
    if not metrics.ws_topic_count then
        return
    end

    local worker_uni_id = misc_utils.get_worker_uni_id()

    return metrics.ws_topic_count:set(topic.get_topic_count(), {worker_uni_id})
end


function _M.set_queue_size()
    if not metrics.ws_msg_queue_size then
        return
    end

    local worker_uni_id = misc_utils.get_worker_uni_id()

    return metrics.ws_msg_queue_size:set(websocket.get_queue_size(), {worker_uni_id})
end


function _M.set_push_log_buffers_size()
    if not metrics.ws_push_log_buffers_size then
        return
    end

    local worker_uni_id = misc_utils.get_worker_uni_id()

    return metrics.ws_push_log_buffers_size:set(log.get_buffers_size(), {worker_uni_id})
end


return _M
