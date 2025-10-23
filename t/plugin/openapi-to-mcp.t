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

    my $extra_init_by_lua = <<_EOC_;
    local server = require("lib.server")
    server.mcp_mock = function()
        ngx.log(ngx.INFO, "mock mcp server: ", ngx.var.request_method, " ", ngx.var.request_uri)

        local headers = ngx.req.get_headers()
        local keys = {}
        for k in pairs(headers) do
            if k:sub(1, 13) == "x-openapi2mcp" then
                table.insert(keys, k)
            end
        end
        table.sort(keys)
        for _, key in ipairs(keys) do
            ngx.log(ngx.INFO, key, ": ", headers[key])
        end

        ngx.exit(200)
    end

    server.mcp = server.mcp_mock
    server._api7_mcp_sse = server.mcp_mock
    server._api7_mcp_mcp_stateless = server.mcp_mock
    server.hello_mcp = server.mcp_mock
_EOC_

    $block->set_value("extra_init_by_lua", $extra_init_by_lua);

    if (!$block->request) {
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
                base_url = "https://petstore.swagger.io",
                headers = {
                    ["Authorization"] = "test-api-key"
                },
                openapi_url = "https://petstore.swagger.io/v2/swagger.json"
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
                base_url = "https://petstore.swagger.io"
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
                            "base_url": "https://petstore.swagger.io",
                            "headers": {
                                "Authorization": "test-api-key"
                            },
                            "openapi_url": "https://petstore.swagger.io/v2/swagger.json"
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
--- yaml_config
plugin_attr:
  openapi-to-mcp:
    port: 1980
--- request
GET /mcp
--- error_log
mock mcp server: GET /.api7_mcp/sse?base_url=https://petstore.swagger.io&openapi_spec=https://petstore.swagger.io/v2/swagger.json&message_path=/mcp&headers.Authorization=test-api-key



=== TEST 5: send POST request should be proxied to message endpoint of mcp server
--- yaml_config
plugin_attr:
  openapi-to-mcp:
    port: 1980
--- request
POST /mcp
--- error_log
mock mcp server: POST /mcp



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
                            "base_url": "https://petstore.swagger.io",
                            "headers": {
                                "Authorization": "test-api-key"
                            },
                            "openapi_url": "https://petstore.swagger.io/v2/swagger.json"
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
--- yaml_config
plugin_attr:
  openapi-to-mcp:
    port: 1980
--- request
POST /mcp
{"method":"tools/list","jsonrpc":"2.0","id":1}
--- error_log
mock mcp server: POST /.api7_mcp/mcp_stateless
x-openapi2mcp-base-url: https://petstore.swagger.io
x-openapi2mcp-header-authorization: test-api-key
x-openapi2mcp-openapi-spec: https://petstore.swagger.io/v2/swagger.json



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
                            "base_url": "https://petstore.swagger.io",
                            "headers": {
                                "Authorization": "${arg_username}-${http_apikey}"
                            },
                            "openapi_url": "https://petstore.swagger.io/v2/swagger.json"
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
--- yaml_config
plugin_attr:
  openapi-to-mcp:
    port: 1980
--- request
POST /mcp?username=alice
{"method":"tools/list","jsonrpc":"2.0","id":1}
--- more_headers
apikey: user-key
--- error_log
mock mcp server: POST /.api7_mcp/mcp_stateless
x-openapi2mcp-base-url: https://petstore.swagger.io
x-openapi2mcp-header-authorization: alice-user-key
x-openapi2mcp-openapi-spec: https://petstore.swagger.io/v2/swagger.json



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
                            "base_url": "https://petstore.swagger.io",
                            "openapi_url": "https://petstore.swagger.io/v2/swagger.json"
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
--- yaml_config
plugin_attr:
  openapi-to-mcp:
    port: 1980
--- request
POST /hello/mcp?sessionID=a332916c-7206-4a60-a9c2-b7ab9ee4e5ed
{"method":"tools/list","jsonrpc":"2.0","id":1}
--- error_log
mock mcp server: POST /hello/mcp?sessionID=a332916c-7206-4a60-a9c2-b7ab9ee4e5ed



=== TEST 12: sse request should be working when no headers in plugin config
--- yaml_config
plugin_attr:
  openapi-to-mcp:
    port: 1980
--- request
GET /hello/mcp
--- error_log
mock mcp server: GET /.api7_mcp/sse?base_url=https://petstore.swagger.io&openapi_spec=https://petstore.swagger.io/v2/swagger.json&message_path=/hello/mcp



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
                            "base_url": "https://petstore.swagger.io",
                            "openapi_url": "https://petstore.swagger.io/v2/swagger.json"
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
--- yaml_config
plugin_attr:
  openapi-to-mcp:
    port: 1980
--- request
POST /mcp
{"method":"tools/list","jsonrpc":"2.0","id":1}
--- error_log
mock mcp server: POST /.api7_mcp/mcp_stateless
x-openapi2mcp-base-url: https://petstore.swagger.io
x-openapi2mcp-openapi-spec: https://petstore.swagger.io/v2/swagger.json
