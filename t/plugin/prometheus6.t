#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
BEGIN {
    if ($ENV{TEST_NGINX_CHECK_LEAK}) {
        $SkipReason = "unavailable for the hup tests";

    } else {
        $ENV{TEST_NGINX_USE_HUP} = 1;
        undef $ENV{TEST_NGINX_USE_STAP};
    }
}

use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_shuffle();
no_root_location();

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!defined $block->request) {
        $block->set_value("request", "GET /t");
    }
});

run_tests;

__DATA__

=== TEST 1: setup public API route and test route
--- config
    location /t {
        content_by_lua_block {
            local data = {
                {
                    url = "/apisix/admin/routes/1",
                    data = [[{
                        "plugins": {
                            "prometheus": {}
                        },
                        "upstream": {
                            "nodes": {
                                "127.0.0.1:1980": 1
                            },
                            "type": "roundrobin"
                        },
                        "uri": "/hello"
                    }]],
                },
                {
                    url = "/apisix/admin/routes/metrics",
                    data = [[{
                        "plugins": {
                            "public-api": {}
                        },
                        "uri": "/apisix/prometheus/metrics"
                    }]]
                },
            }

            local t = require("lib.test_admin").test

            for _, data in ipairs(data) do
                local code, body = t(data.url, ngx.HTTP_PUT, data.data)
                ngx.say(code..body)
            end
        }
    }
--- response_body eval
"201passed\n" x 2



=== TEST 2: should disable prometheus when shared dict is full
--- yaml_config
plugin_attr:
    prometheus:
        allow_degradation: true
nginx_config:
  meta:
    lua_shared_dict:
      prometheus-metrics: 1m
--- extra_init_worker_by_lua
  prometheus = require("prometheus").init("prometheus-metrics-advanced")
  metric_requests = prometheus:counter(
    "nginx_http_requests_total", "Number of HTTP requests", {"host", "status"})
	for i = 1, 100000 do
		metric_requests:inc(1, {"test" .. i, 200})
	end
--- request
GET /apisix/prometheus/metrics
--- timeout: 10
--- error_log
Disabling for 60 seconds



=== TEST 3: should not disable prometheus when shared dict is full
--- yaml_config
plugin_attr:
    prometheus:
        allow_degradation: false
nginx_config:
  meta:
    lua_shared_dict:
      prometheus-metrics: 1m
--- extra_init_worker_by_lua
  prometheus = require("prometheus").init("prometheus-metrics-advanced")
  metric_requests = prometheus:counter(
    "nginx_http_requests_total", "Number of HTTP requests", {"host", "status"})
	for i = 1, 100000 do
		metric_requests:inc(1, {"test" .. i, 200})
	end
--- request
GET /apisix/prometheus/metrics
--- timeout: 10
--- no_error_log
Disabling for 60 seconds
