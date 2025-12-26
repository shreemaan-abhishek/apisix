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
no_long_string();
no_shuffle();
no_root_location();

add_block_preprocessor(sub {
    my ($block) = @_;

    my $extra_yaml_config = $block->extra_yaml_config // <<_EOC_;
plugin_attr:
  openapi-to-mcp:
    port: 13000
_EOC_

    $block->set_value("extra_yaml_config", $extra_yaml_config);

    if (!$block->request || !$block->exec) {
        $block->set_value("request", "GET /t");
    }

    if (!$block->error_log && !$block->no_error_log) {
        $block->set_value("no_error_log", "[error]\n[alert]");
    }
});

run_tests;

__DATA__

=== TEST 1: sanity
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.openapi-to-mcp")
            local ok, err = plugin.check_schema({
                base_url = "http://petstore3.local:8281/api/v3",
                headers = {
                    ["Authorization"] = "test-api-key"
                },
                openapi_url = "http://petstore3.local:8281/api/v3/openapi.json"
            })
            if not ok then
                ngx.say(err)
                return
            end

            ngx.say("done")
        }
    }
--- response_body
done



=== TEST 2: missing required fields
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.openapi-to-mcp")
            local ok, err = plugin.check_schema({
                base_url = "http://petstore3.local:8281/api/v3"
            })
            if not ok then
                ngx.say(err)
                return
            end

            ngx.say("done")
        }
    }
--- response_body
property "openapi_url" is required



=== TEST 3: create a route with openapi-to-mcp plugin
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "uri": "/mcp",
                    "plugins": {
                        "openapi-to-mcp": {
                            "base_url": "http://petstore3.local:8281/api/v3",
                            "headers": {
                                "Authorization": "test-api-key"
                            },
                            "openapi_url": "http://petstore3.local:8281/api/v3/openapi.json"
                        }
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    }
                }]]
            )

            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 4: send GET request should be proxied to sse endpoint of mcp server
--- exec
timeout 1 curl -X GET -N -sS http://localhost:1984/mcp 2>&1 | cat
--- response_body_like
event:\s*endpoint
data:\s*/mcp\?sessionId=.*



=== TEST 5: send POST request should be proxied to message endpoint of mcp server
--- exec
timeout 1 curl -X POST -N -sS http://localhost:1984/mcp 2>&1 | cat
--- response_body eval
qr/\{\"jsonrpc\":\"2.0\",\"error\":\{\"code\":-32000,\"message\":\"Missing or invalid sessionId parameter\"},\"id\":null}/



=== TEST 6: create a route with openapi-to-mcp plugin that using streamable http transport
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "uri": "/mcp",
                    "plugins": {
                        "openapi-to-mcp": {
                            "transport": "streamable_http",
                            "base_url": "http://petstore3.local:8281/api/v3",
                            "headers": {
                                "Authorization": "test-api-key"
                            },
                            "openapi_url": "http://petstore3.local:8281/api/v3/openapi.json"
                        }
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    }
                }]]
            )

            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 7: send tools/list request should be proxied to stateless endpoint of mcp server
--- log_level: debug
--- max_size: 2048000
--- exec
timeout 1 curl -X POST -N -sS http://localhost:1984/mcp \
    -d '{"method":"tools/list","jsonrpc":"2.0","id":1}' \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    2>&1 | cat
--- response_body eval
qr/event: message\ndata: \{\"result\":\{\"tools\":.+},\"jsonrpc\":\"2.0\",\"id\":1}/
--- error_log eval
qr/x-openapi2mcp-header-Authorization: test-api-key/



=== TEST 8: openapi-to-mcp's headers can use variables
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "uri": "/mcp",
                    "plugins": {
                        "openapi-to-mcp": {
                            "transport": "streamable_http",
                            "base_url": "http://petstore3.local:8281/api/v3",
                            "headers": {
                                "Authorization": "${arg_username}-${http_apikey}"
                            },
                            "openapi_url": "http://petstore3.local:8281/api/v3/openapi.json"
                        }
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    }
                }]]
            )

            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 9: confirm that variables in headers are correctly replaced
--- log_level: debug
--- max_size: 2048000
--- exec
timeout 1 curl -X POST -N -sS http://localhost:1984/mcp?username=alice \
    -d '{"method":"tools/list","jsonrpc":"2.0","id":1}' \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "apikey: user-key" \
    2>&1 | cat
--- response_body eval
qr/event: message\ndata: \{\"result\":\{\"tools\":.+},\"jsonrpc\":\"2.0\",\"id\":1}/
--- error_log eval
qr/x-openapi2mcp-header-Authorization: alice-user-key/



=== TEST 10: use sse tranport with path_prefix and strip_path_prefix
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/services/1',
                 ngx.HTTP_PUT,
                 [[{
                    "path_prefix": "/hello",
                    "strip_path_prefix": true,
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    }
                }]]
            )

            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "uri": "/mcp",
                    "plugins": {
                        "openapi-to-mcp": {
                            "transport": "sse",
                            "base_url": "http://petstore3.local:8281/api/v3",
                            "openapi_url": "http://petstore3.local:8281/api/v3/openapi.json"
                        }
                    },
                    "service_id": 1
                }]]
            )

            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 11: confirm sse message request that send with path_prefix to MCP server
--- exec
timeout 1 curl -X POST -N -sS http://localhost:1984/hello/mcp?sessionId=a332916c-7206-4a60-a9c2-b7ab9ee4e5ed \
    -d '{"method":"tools/list","jsonrpc":"2.0","id":1}' \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    2>&1 | cat
--- response_body eval
qr/\{\"jsonrpc\":\"2.0\",\"error\":\{\"code\":-32000,\"message\":\"Session not found for sessionId\"},\"id\":null}/



=== TEST 12: sse request should be working when no headers in plugin config
--- exec
timeout 1 curl -X GET -N -sS http://localhost:1984/hello/mcp 2>&1 | cat
--- response_body_like
event:\s*endpoint
data:\s*/hello/mcp\?sessionId=.*



=== TEST 13: streamable_http without headers
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "uri": "/mcp",
                    "plugins": {
                        "openapi-to-mcp": {
                            "transport": "streamable_http",
                            "base_url": "http://petstore3.local:8281/api/v3",
                            "openapi_url": "http://petstore3.local:8281/api/v3/openapi.json"
                        }
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    }
                }]]
            )

            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 14: mcp request should be working when no headers in plugin config
--- log_level: debug
--- max_size: 2048000
--- exec
timeout 1 curl -X POST -N -sS http://localhost:1984/mcp \
    -d '{"method":"tools/list","jsonrpc":"2.0","id":1}' \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    2>&1 | cat
--- response_body eval
qr/event: message\ndata: \{\"result\":\{\"tools\":.+},\"jsonrpc\":\"2.0\",\"id\":1}/
--- no_error_log eval
qr/x-openapi2mcp-header-authorization/



=== TEST 15: create a route with openapi-to-mcp plugin
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "uri": "/mcp",
                    "plugins": {
                        "openapi-to-mcp": {
                            "base_url": "http://${http_variable_host}/api/v3",
                            "headers": {
                                "Authorization": "test-api-key"
                            },
                            "openapi_url": "http://petstore3.local:8281/api/v3/openapi.json"
                        },
                        "serverless-post-function": {
                            "phase": "access",
                            "functions": [
                                "return function(conf, ctx)
                                    local core = require(\"apisix.core\")
                                    local headers = ngx.req.get_headers()
                                    core.log.error(\"[upstream headers] \", core.json.encode(headers))
                                end"
                            ]
                        }
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    }
                }]]
            )

            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 16: send GET request should be proxied to sse endpoint of mcp server
--- log_level: debug
--- exec
timeout 1 curl -X GET -N -sS http://localhost:1984/mcp \
    -H "variable_host: petstore.local:8281"
    2>&1 | cat
--- response_body_like
event:\s*endpoint
data:\s*/mcp\?sessionId=.*
--- error_log eval
qr/"x-openapi2mcp-base-url":\s*"http:\/\/petstore\.local:8281\/api\/v3"/



=== TEST 17: schema validation with flatten_parameters
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.openapi-to-mcp")
            local ok, err = plugin.check_schema({
                base_url = "http://petstore3.local:8281/api/v3",
                openapi_url = "http://petstore3.local:8281/api/v3/openapi.json",
                flatten_parameters = true
            })
            if not ok then
                ngx.say(err)
                return
            end

            local ok, err = plugin.check_schema({
                base_url = "http://petstore3.local:8281/api/v3",
                openapi_url = "http://petstore3.local:8281/api/v3/openapi.json",
                flatten_parameters = false
            })
            if not ok then
                ngx.say(err)
                return
            end

            ngx.say("done")
        }
    }
--- response_body
done



=== TEST 18: flatten_parameters should be passed to MCP server via header in sse transport
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "uri": "/mcp",
                    "plugins": {
                        "openapi-to-mcp": {
                            "base_url": "http://petstore3.local:8281/api/v3",
                            "openapi_url": "http://petstore3.local:8281/api/v3/openapi.json",
                            "flatten_parameters": true
                        },
                        "serverless-post-function": {
                            "phase": "access",
                            "functions": [
                                "return function(conf, ctx)
                                    local core = require(\"apisix.core\")
                                    local headers = ngx.req.get_headers()
                                    core.log.error(\"[upstream headers] \", core.json.encode(headers))
                                end"
                            ]
                        }
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    }
                }]]
            )

            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 19: verify flatten_parameters in sse transport header
--- log_level: debug
--- exec
timeout 1 curl -X GET -N -sS http://localhost:1984/mcp 2>&1 | cat
--- response_body_like
event:\s*endpoint
data:\s*/mcp\?sessionId=.*
--- error_log eval
qr/"x-openapi2mcp-flatten-parameters":\s*"true"/



=== TEST 20: flatten_parameters false should be passed to MCP server in sse transport
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "uri": "/mcp",
                    "plugins": {
                        "openapi-to-mcp": {
                            "base_url": "http://petstore3.local:8281/api/v3",
                            "openapi_url": "http://petstore3.local:8281/api/v3/openapi.json",
                            "flatten_parameters": false
                        },
                        "serverless-post-function": {
                            "phase": "access",
                            "functions": [
                                "return function(conf, ctx)
                                    local core = require(\"apisix.core\")
                                    local headers = ngx.req.get_headers()
                                    core.log.error(\"[upstream headers] \", core.json.encode(headers))
                                end"
                            ]
                        }
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    }
                }]]
            )

            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 21: verify flatten_parameters false in sse transport header
--- log_level: debug
--- exec
timeout 1 curl -X GET -N -sS http://localhost:1984/mcp 2>&1 | cat
--- response_body_like
event:\s*endpoint
data:\s*/mcp\?sessionId=.*
--- error_log eval
qr/"x-openapi2mcp-flatten-parameters":\s*"false"/



=== TEST 22: flatten_parameters should be passed to MCP server via header in streamable_http transport
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "uri": "/mcp",
                    "plugins": {
                        "openapi-to-mcp": {
                            "transport": "streamable_http",
                            "base_url": "http://petstore3.local:8281/api/v3",
                            "openapi_url": "http://petstore3.local:8281/api/v3/openapi.json",
                            "flatten_parameters": true
                        }
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    }
                }]]
            )

            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 23: verify flatten_parameters in streamable_http transport header
--- max_size: 2048000
--- exec
timeout 1 curl -X POST -N -sS http://localhost:1984/mcp \
    -d '{"method":"tools/list","jsonrpc":"2.0","id":1}' \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    2>&1 | cat
--- response_body eval
qr/(?s)^(?:(?!queryParameters).)*$/



=== TEST 24: flatten_parameters false in streamable_http transport
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "uri": "/mcp",
                    "plugins": {
                        "openapi-to-mcp": {
                            "transport": "streamable_http",
                            "base_url": "http://petstore3.local:8281/api/v3",
                            "openapi_url": "http://petstore3.local:8281/api/v3/openapi.json",
                            "flatten_parameters": false
                        }
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    }
                }]]
            )

            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 25: verify flatten_parameters false in streamable_http transport header
--- max_size: 2048000
--- exec
timeout 1 curl -X POST -N -sS http://localhost:1984/mcp \
    -d '{"method":"tools/list","jsonrpc":"2.0","id":1}' \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    2>&1 | cat
--- response_body eval
qr/queryParameters/



=== TEST 26: verify mcp tools call works
--- exec
timeout 1 curl -X POST -N -sS http://localhost:1984/mcp \
    -d '{
    "jsonrpc": "2.0",
    "method": "tools/call",
    "params": {
      "name": "findPetsByStatus",
      "arguments": {
        "queryParameters": {
          "status": "pending"
          }
        }
      },
      "id": 1
    }' \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    2>&1 | cat
--- response_body eval
qr/\\"status\\": \\"pending\\"/s
