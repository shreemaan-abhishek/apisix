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
use t::APISIX 'no_plan';

repeat_each(1);
log_level('info');
no_root_location();
no_shuffle();

add_block_preprocessor(sub {
    my ($block) = @_;

    my $http_config = $block->http_config // <<_EOC_;
        # fake server, only for test
        server {
            listen 1970;
            location / {
                content_by_lua_block {
                    ngx.print(1970)
                }
            }
        }

        server {
            listen 1971;
            location / {
                content_by_lua_block {
                    ngx.print(1971)
                }
            }
        }

        server {
            listen 1972;
            location / {
                content_by_lua_block {
                    ngx.print(1972)
                }
            }
        }
_EOC_

    $block->set_value("http_config", $http_config);

    if (!$block->request) {
        $block->set_value("request", "GET /t");
    }

    if (!$block->error_log && !$block->no_error_log) {
        $block->set_value("no_error_log", "[error]\n[alert]");
    }
});

run_tests;

__DATA__

=== TEST 1: api7-traffic-split - set upstream(id: 0)
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/upstreams/0',
                 ngx.HTTP_PUT,
                [[{
                    "nodes": {
                        "127.0.0.1:1980": 1
                    },
                    "type": "roundrobin",
                    "desc": "new upstream"
                }]]
                )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 2: api7-traffic-split - set upstream(id: 1)
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/upstreams/1',
                 ngx.HTTP_PUT,
                 [[{
                    "nodes": {
                        "127.0.0.1:1971": 2,
                        "127.0.0.1:1981": 1
                    },
                    "type": "roundrobin",
                    "desc": "new upstream"
                }]]
                )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 3: api7-traffic-split - set upstream(id: 2)
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/upstreams/2',
                 ngx.HTTP_PUT,
                [[{
                    "nodes": {
                        "127.0.0.1:1972": 2,
                        "127.0.0.1:1982": 1
                    },
                    "type": "roundrobin",
                    "desc": "new upstream"
                }]]
                )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 4: api7-traffic-split - schema check - upstreams[].name require
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.api7-traffic-split")

            --
            local conf = {
                upstreams = {
                    {
                        name = "",
                        type = "roundrobin",
                        id = "1",
                    },
                },
            }

            local ok, err = plugin.check_schema(conf)

            if not ok then
                ngx.say(err)
                return
            end

            ngx.say("passed")
        }
    }
--- response_body
property "upstreams" validation failed: failed to validate item 1: property "name" validation failed: string too short, expected at least 1, got 0



=== TEST 5: api7-traffic-split - schema check - upstreams[].name unique check
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.api7-traffic-split")

            --
            local conf = {
                upstreams = {
                    {
                        name = "test",
                        type = "roundrobin",
                        id = "1",
                    },
                    {
                        name = "test",
                        type = "roundrobin",
                        id = "2",
                    },
                },
            }

            local ok, err = plugin.check_schema(conf)

            if not ok then
                ngx.say(err)
                return
            end

            ngx.say("passed")
        }
    }
--- response_body
duplicate upstream [2] name found: test



=== TEST 6: api7-traffic-split - schema check - upstreams[].name reference check
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.api7-traffic-split")

            --
            local conf = {
                rules = {
                    {
                        canary_upstreams = {
                            {
                                upstream_name = "not-exist-upstream-name",
                            },
                        },
                    },
                },
                upstreams = {
                    {
                        name = "test",
                        type = "roundrobin",
                        id = "1",
                    },
                },
            }

            local ok, err = plugin.check_schema(conf)

            if not ok then
                ngx.say(err)
                return
            end

            ngx.say("passed")
        }
    }
--- response_body
failed to fetch rules[1].canary_upstreams[1].upstream_name: [not-exist-upstream-name] in conf.upstreams



=== TEST 7: api7-traffic-split - sanity test
--- config
    location /t {
        content_by_lua_block {
            local json = require("toolkit.json")
            local t = require("lib.test_admin").test
            local data = {
                uri = "/server_port",
                plugins = {
                    ["api7-traffic-split"] = {
                        rules = {
                            {
                                match = { {
                                    exprs = { { "arg_id", "==", "1" } }
                                } },
                                canary_upstreams = {
                                    {
                                        upstream_name = "test1",
                                    },
                                },
                            },
                            {
                                match = { {
                                    exprs = { { "arg_id", "==", "2" } }
                                } },
                                canary_upstreams = {
                                    {
                                        upstream_name = "test2",
                                    },
                                },
                            },
                        },
                        upstreams = {
                            {
                                name = "test1",
                                type = "roundrobin",
                                id = "1",
                            },
                            {
                                name = "test2",
                                type = "roundrobin",
                                id = "2",
                            },
                        },
                    },
                },
                upstream_id = "0",
            }
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                json.encode(data)
            )
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 8: api7-traffic-split - hit different canary_upstreams by rules
--- config
    location /t {
        content_by_lua_block {
            local http = require("resty.http")
            local httpc = http.new()

            local uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/server_port"
            local res, err = httpc:request_uri(uri)
            local port = tonumber(res.body)
            if port ~= 1980 then
                ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
                ngx.say("failed while no arg_id - ", res.body)
                return
            end

            uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/server_port?id=1"
            res, err = httpc:request_uri(uri)
            port = tonumber(res.body)
            if port ~= 1971 and port ~= 1981 then
                ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
                ngx.say("failed while arg_id = 1 - ", res.body)
                return
            end

            uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/server_port?id=2"
            res, err = httpc:request_uri(uri)
            port = tonumber(res.body)
            if port ~= 1972 and port ~= 1982 then
                ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
                ngx.say("failed while arg_id = 2 - ", res.body)
                return
            end

            ngx.say("passed")
        }
    }
--- response_body
passed



=== TEST 9: api7-traffic-split - pick different nodes by weight
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.http"
            local httpc = http.new()

            local uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/server_port?id=1"
            local ports = {}
            local res, err
            for i = 1, 3 do
                res, err = httpc:request_uri(uri)
                local port = tonumber(res.body)
                ports[i] = port
            end
            table.sort(ports)

            local uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/server_port?id=2"
            for i = 4, 6 do
                res, err = httpc:request_uri(uri)
                local port = tonumber(res.body)
                ports[i] = port
            end
            table.sort(ports)

            ngx.say(table.concat(ports, ", "))
        }
    }
--- response_body
1971, 1971, 1972, 1972, 1981, 1982



=== TEST 10: api7-traffic-split - set upstream(multiple rules, the first rule has the match attribute and the second rule does not) and add route
--- config
    location /t {
        content_by_lua_block {
            local json = require("toolkit.json")
            local t = require("lib.test_admin").test
            local data = {
                uri = "/server_port",
                plugins = {
                    ["api7-traffic-split"] = {
                        rules = {
                            {
                                match = { {
                                    exprs = { { "arg_id", "==", "1" } }
                                } },
                                canary_upstreams = {
                                    {
                                        upstream_name = "test1",
                                        weight = 1,
                                    },
                                },
                            },
                            {
                                canary_upstreams = {
                                    {
                                        upstream_name = "test2",
                                        weight = 1,
                                    },
                                    {
                                        weight = 1,
                                    }
                                },
                            },
                        },
                        upstreams = {
                            {
                                name = "test1",
                                type = "roundrobin",
                                id = "1",
                            },
                            {
                                name = "test2",
                                type = "roundrobin",
                                id = "2",
                            },
                        },
                    },
                },
                upstream_id = "0",
            }
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                json.encode(data)
            )
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 11: api7-traffic-split - first rule match failed and the second rule match success
--- config
    location /t {
        content_by_lua_block {
            local http = require("resty.http")
            local httpc = http.new()

            local uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/server_port?id=1"
            local ports = {}
            local res, err
            for i = 1, 3 do
                res, err = httpc:request_uri(uri)
                local port = tonumber(res.body)
                ports[i] = port
            end

            local uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/server_port?id=2"
            for i = 4, 7 do
                res, err = httpc:request_uri(uri)
                local port = tonumber(res.body)
                ports[i] = port
            end
            table.sort(ports)

            ngx.say(table.concat(ports, ", "))
        }
    }
--- response_body
1971, 1971, 1972, 1980, 1980, 1981, 1982



=== TEST 12: api7-traffic-split - set route(id: 1, upstream_id: 1, upstream_id in plugin: 2), and `weighted_upstreams` does not have a structure with only `weight`
--- config
    location /t {
        content_by_lua_block {
            local json = require("toolkit.json")
            local t = require("lib.test_admin").test
            local data = {
                uri = "/server_port",
                plugins = {
                    ["api7-traffic-split"] = {
                        rules = {
                            {
                                match = { {
                                    exprs = { { "arg_id", "==", "2" } }
                                } },
                                canary_upstreams = {
                                    {
                                        upstream_name = "test2",
                                    },
                                },
                            },
                        },
                        upstreams = {
                            {
                                name = "test1",
                                type = "roundrobin",
                                id = "1",
                            },
                            {
                                name = "test2",
                                type = "roundrobin",
                                id = "2",
                            },
                        },
                    },
                },
                upstream_id = "0",
            }
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                json.encode(data)
            )
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 13: api7-traffic-split - when `match` rule passed, use the `upstream_id` in plugin, and when it failed, use the `upstream_id` in route
--- config
location /t {
    content_by_lua_block {
        local core = require("apisix.core")
        local t = require("lib.test_admin").test
        local bodys = {}

        for i = 1, 5, 2 do
            -- match rule passed
            local _, _, body = t('/server_port?id=2', ngx.HTTP_GET)
            bodys[i] = body

            -- match rule failed
            local _, _, body = t('/server_port', ngx.HTTP_GET)
            bodys[i+1] = body
        end

        table.sort(bodys)
        ngx.say(table.concat(bodys, ", "))
    }
}
--- response_body
1972, 1972, 1980, 1980, 1980, 1982



=== TEST 14: api7-traffic-split - update upstream(id: 2) - add not-exist upstream node
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/upstreams/2',
                 ngx.HTTP_PUT,
                 [[{
                    "nodes": {
                        "127.0.0.1:1992": 2,
                        "127.0.0.1:1982": 1
                    },
                    "type": "roundrobin",
                    "desc": "new upstream",
                    "checks": {
                        "active": {
                            "http_path": "/status",
                            "host": "127.0.0.1",
                            "healthy": {
                               "interval": 2,
                               "successes": 1
                            },
                            "unhealthy": {
                               "interval": 1,
                               "http_failures": 2
                            }
                        }
                    }
                }]]
                )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 15: api7-traffic-split - healthcheck
--- config
location /t {
    content_by_lua_block {
        local core = require("apisix.core")
        local t = require("lib.test_admin").test
        local bodys = {}

        for i = 1, 5, 2 do
            -- match rule passed
            local _, _, body = t('/server_port?id=2', ngx.HTTP_GET)
            bodys[i] = body

            -- match rule failed
            local _, _, body = t('/server_port', ngx.HTTP_GET)
            bodys[i+1] = body
        end

        table.sort(bodys)
        ngx.say(table.concat(bodys, ", "))
    }
}
--- response_body
1980, 1980, 1980, 1982, 1982, 1982
--- error_log
Connection refused
