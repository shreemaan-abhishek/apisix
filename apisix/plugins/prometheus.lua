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
local core = require("apisix.core")
local exporter = require("apisix.plugins.prometheus.exporter")
local plugin    = require("apisix.plugin")
local ngx = ngx
local error = error
local pcall = pcall
local prometheus_keys = require("prometheus_keys")
local process = require("ngx.process")
local org_add = prometheus_keys.add
local plugin_name = "prometheus"
local status_dict = ngx.shared["prometheus-status"]
if not status_dict then
    error('shared dict prometheus-status not defined')
end
local metric_dict = ngx.shared["prometheus-metrics-advanced"]
if not metric_dict then
    error('shared dict prometheus-metrics-advanced not defined')
end
local status_version = 0
local disabled = false

prometheus_keys.add = function(...)
    local err = org_add(...)
    if err and err:find("Shared dictionary used for prometheus metrics is full", 1, true) then
        status_dict:set("memory_full", true)
    end
    return err
end


local metadata_schema = {
    type = "object",
    properties = {
        disabled_labels = {
            type = "object",
            properties = {
                status = {
                    type = "array",
                    items = {
                        type = "string",
                        enum = {"code", "route", "route_id", "matched_uri", "matched_host",
                                "service", "service_id", "consumer", "node"},
                    },
                },
                latency = {
                    type = "array",
                    items = {
                        type = "string",
                        enum = {"type", "route", "route_id", "service",
                                "service_id", "consumer", "node"},
                    },
                },
                bandwidth = {
                    type = "array",
                    items = {
                        type = "string",
                        enum = {"type", "route", "route_id", "service",
                                "service_id", "consumer", "node"},
                    },
                },
            },
            additionalProperties = false,
        },
    },
}



local schema = {
    type = "object",
    properties = {
        prefer_name = {
            type = "boolean",
            default = false
        }
    },
}


local _M = {
    version = 0.2,
    priority = 500,
    name = plugin_name,
    schema = schema,
    metadata_schema = metadata_schema,
    run_policy = "prefer_route",
    destroy = exporter.destroy,
}


function _M.check_schema(conf, schema_type)
    if schema_type == core.schema.TYPE_METADATA then
        return core.schema.check(metadata_schema, conf)
    end
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end

    return true
end

function _M.log(conf, ctx)
    if disabled then
        core.log.info("prometheus plugin is disabled")
        return
    end
    return exporter.http_log(conf, ctx)
end

function _M.api()
    return exporter.get_api(true)
end

local function disable_prometheus(pause_duration)
    core.log.error("Shared dictionary used for prometheus metrics is full ",
                   "please increase the size of the shared dict. Disabling for ",
                   pause_duration, " seconds")
    status_dict:set("disabled", true)
    status_dict:incr("version", 1, 1)
    -- wait for all pending http_log phases to be done
    ngx.sleep(2)
    metric_dict:flush_all()
    metric_dict:flush_expired()
    exporter.reset()
    status_dict:set("memory_full", false)
    ngx.sleep(pause_duration)
    status_dict:set("disabled", false)
    status_dict:incr("version", 1, 1)
    core.log.info("Prometheus metrics collection is enabled again")
end

function _M.init_degradation_timer(self)
    local attr = plugin.plugin_attr("prometheus")
    if not attr or not attr.allow_degradation then
        return
    end
    -- Currently only one value is used for pausing prometheus
    -- TODO: Support degradation_pause_steps to support multiple subsequent pause intervals
    local pause_duration = (attr and attr.degradation_pause_steps
                                and attr.degradation_pause_steps[1]) or 60
    ngx.timer.every(1, function (premature)
        if premature then
            return
        end
        if process.type() == "privileged agent" then
            if self.disabling then
                return
            end
            self.disabling = true
            if status_dict:get("memory_full") then
                local ok, err = pcall(disable_prometheus, pause_duration)
                if not ok then
                    core.log.error("failed to disable prometheus metrics collection: ", err)
                end
            end
            self.disabling = false
            return
        end
        local version = status_dict:get("version")
        if not version or version == status_version then
            return
        end
        status_version = version
        disabled = status_dict:get("disabled") or false
        if disabled then
            exporter.reset()
        end
    end)
end

return _M
