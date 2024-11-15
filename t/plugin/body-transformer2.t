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

no_long_string();
no_shuffle();
no_root_location();

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!$block->request) {
        $block->set_value("request", "GET /t");
    }
});

run_tests;

__DATA__

=== TEST 1: body transformer plugin with key-auth that fails
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin")
            local core = require("apisix.core")

            local code, body = t.test('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/foobar",
                    "plugins": {
                        "body-transformer": {
                            "request": {
                                "template": "some-template"
                            }
                        },
                        "key-auth": {}
                    },
                    "upstream": {
                        "type": "roundrobin",
                        "nodes": {
                            "127.0.0.1:1980": 1
                        }
                    }
                }]]
            )

            if code >= 300 then
                ngx.status = code
                return
            end
            ngx.sleep(0.5)

            local http = require("resty.http")
            local uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/foobar"

            local opt = {method = "POST", body = "body", headers = {["Content-Type"] = "application/json"}}
            local httpc = http.new()
            local res = httpc:request_uri(uri, opt)

            assert(res.status == 401)            
            ngx.say(res.reason)
        }
    }
--- response_body
Unauthorized



=== TEST 2: body transformer with decoded body (keyword: context)
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin")
            local core = require("apisix.core")

            local req_template = ngx.encode_base64[[
                {%
                    local core = require 'apisix.core'
                    local cjson = require 'cjson'
                    context.name = "bar"
                    context.address = nil
                    context.age = context.age + 1
                    local body = core.json.encode(context)
                %}{* body *}
            ]]

            local code, body = t.test('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                string.format([[{
                    "uri": "/echo",
                    "plugins": {
                        "body-transformer": {
                            "request": {
                                "template": "%s"
                            }
                        }
                    },
                    "upstream": {
                        "type": "roundrobin",
                        "nodes": {
                            "127.0.0.1:1980": 1
                        }
                    }
                }]], req_template)
            )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 3: verify the transformed body
--- request
POST /echo
{"name": "foo", "address":"LA", "age": 18}
-- response_body
{"name": "bar", "age": 19}



=== TEST 4: multipart request body to json request body conversion
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin")
            local core = require("apisix.core")

            local code, body = t.test('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/echo",
                    "plugins": {
                        "body-transformer": {
                            "request": {
                                "template": "{\"foo\":\"{{name .. \" world\"}}\",\"bar\":{{age+10}}}"
                            }
                        }
                    },
                    "upstream": {
                        "type": "roundrobin",
                        "nodes": {
                            "127.0.0.1:1980": 1
                        }
                    }
                }]]
            )

            if code >= 300 then
                ngx.status = code
                return
            end
            ngx.sleep(0.5)

            local http = require("resty.http")
            local uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/echo"

            local body = ([[
--AaB03x
Content-Disposition: form-data; name="name"

Larry
--AaB03x
Content-Disposition: form-data; name="age"

10
--AaB03x--]])

            local opt = {method = "POST", body = body, headers = {["Content-Type"] = "multipart/related; boundary=AaB03x"}}
            local httpc = http.new()
            local res = httpc:request_uri(uri, opt)

            ngx.status = res.status
            ngx.say(res.body or res.reason)
        }
    }
--- response_body
{"foo":"Larry world","bar":20}



=== TEST 5: multipart response body to json response body conversion
--- config
    location /demo {
        content_by_lua_block {
            ngx.header["Content-Type"] = "multipart/related; boundary=AaB03x"
            ngx.say([[
--AaB03x
Content-Disposition: form-data; name="name"

Larry
--AaB03x
Content-Disposition: form-data; name="age"

10
--AaB03x--]])
        }
    }
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin")
            local core = require("apisix.core")

            local code, body = t.test('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/hello",
                    "plugins": {
                        "proxy-rewrite": {
                            "uri": "/demo"
                        },
                        "body-transformer": {
                            "response": {
                                "template": "{\"foo\":\"{{name .. \" world\"}}\",\"bar\":{{age+10}}}"
                            }
                        }
                    },
                    "upstream": {
                        "type": "roundrobin",
                        "nodes": {
                            "127.0.0.1:1984": 1
                        }
                    }
                }]]
            )

            if code >= 300 then
                ngx.status = code
                return
            end
            ngx.sleep(0.5)

            local http = require("resty.http")
            local uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/hello"

            local opt = {method = "GET"}
            local httpc = http.new()
            local res = httpc:request_uri(uri, opt)

            ngx.status = res.status
            ngx.say(res.body or res.reason)
        }
    }
--- response_body
{"foo":"Larry world","bar":20}
