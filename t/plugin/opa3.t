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
no_root_location();

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!defined $block->request) {
        $block->set_value("request", "GET /t");
    }
});

run_tests();

__DATA__

=== TEST 1: setup mock OPA route and protected route
--- config
    location /t {
        content_by_lua_block {
            local data = {
                {
                    url = "/apisix/admin/upstreams/u1",
                    data = [[{
                        "nodes": {
                            "127.0.0.1:1984": 1
                        },
                        "type": "roundrobin"
                    }]],
                },
                {
                    -- mock OPA: returns allow=true with NO headers field
                    url = "/apisix/admin/routes/opa_mock",
                    data = {
                        plugins = {
                            ["serverless-pre-function"] = {
                                phase = "rewrite",
                                functions =  {
                                    [[return function(conf, ctx)
                                        local core = require("apisix.core")
                                        core.response.exit(200, {result = {allow = true}})
                                    end]]
                                }
                            }
                        },
                        uri = "/v1/data/example"
                    },
                },
                {
                    url = "/apisix/admin/routes/1",
                    data = [[{
                        "plugins": {
                            "opa": {
                                "host": "http://127.0.0.1:1984",
                                "policy": "example",
                                "send_headers_upstream": ["X-Foo"]
                            },
                            "serverless-post-function": {
                                "phase": "access",
                                "functions": [
                                    "return function(conf, ctx) local core = require(\"apisix.core\"); core.response.exit(200, core.request.headers(ctx)); end"
                                ]
                            }
                        },
                        "upstream_id": "u1",
                        "uri": "/echo"
                    }]],
                }
            }

            local t = require("lib.test_admin").test

            for _, data in ipairs(data) do
                local code, body = t(data.url, ngx.HTTP_PUT, data.data)
                ngx.say(body)
            end
        }
    }
--- response_body eval
"passed\n" x 3



=== TEST 2: client-supplied send_headers_upstream entry is cleared when OPA omits it
--- request
GET /echo
--- more_headers
X-Foo: spoofed
--- response_body_unlike eval
qr/spoofed/
