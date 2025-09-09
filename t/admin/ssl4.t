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

log_level('debug');
no_root_location();

add_block_preprocessor( sub{
    my ($block) = @_;

    if (!$block->request) {
        $block->set_value("request", "GET /t");
    }

    my $TEST_NGINX_HTML_DIR ||= html_dir();
}

);


run_tests;

__DATA__

=== TEST 1: set ssl(sni: www.test.com), encrypt with the first keyring
--- yaml_config
apisix:
    node_listen: 1984
    data_encryption:
        keyring:
            - edd1c9f0985e76a1
--- config
location /t {
    content_by_lua_block {
        local core = require("apisix.core")
        local t = require("lib.test_admin")

        local ssl_cert = t.read_file("t/certs/apisix.crt")
        local ssl_key =  t.read_file("t/certs/apisix.key")
        local data = {cert = ssl_cert, key = ssl_key, sni = "test.com"}

        local code, body = t.test('/apisix/admin/ssls/1',
            ngx.HTTP_PUT,
            core.json.encode(data),
            [[{
                "value": {
                    "sni": "test.com"
                },
                "key": "/apisix/ssls/1"
            }]]
            )

        ngx.status = code
        ngx.say(body)
    }
}
--- response_body
passed



=== TEST 2: set route(id: 1)
--- yaml_config
apisix:
    node_listen: 1984
    data_encryption:
        keyring: 
            - edd1c9f0985e76a1
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                        "upstream": {
                            "nodes": {
                                "127.0.0.1:1980": 1
                            },
                            "type": "roundrobin"
                        },
                        "uri": "/hello"
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



=== TEST 3: update encrypt keyring, and set ssl(sni: test2.com)
--- yaml_config
apisix:
    node_listen: 1984
    data_encryption:
        keyring:
            - qeddd145sfvddff3
            - edd1c9f0985e76a1
--- config
location /t {
    content_by_lua_block {
        local core = require("apisix.core")
        local t = require("lib.test_admin")

        local ssl_cert = t.read_file("t/certs/test2.crt")
        local ssl_key =  t.read_file("t/certs/test2.key")
        local data = {cert = ssl_cert, key = ssl_key, sni = "test2.com"}

        local code, body = t.test('/apisix/admin/ssls/2',
            ngx.HTTP_PUT,
            core.json.encode(data),
            [[{
                "value": {
                    "sni": "test2.com"
                },
                "key": "/apisix/ssls/2"
            }]]
            )

        ngx.status = code
        ngx.say(body)
    }
}
--- response_body
passed



=== TEST 4: Successfully access test.com
--- yaml_config
apisix:
    node_listen: 1984
    data_encryption:
        keyring:
            - qeddd145sfvddff3
            - edd1c9f0985e76a1
--- exec
curl -k -s --resolve "test2.com:1994:127.0.0.1" https://test2.com:1994/hello 2>&1 | cat
--- response_body
hello world



=== TEST 5: Successfully access test2.com
--- yaml_config
apisix:
    node_listen: 1984
    data_encryption:
        keyring:
            - qeddd145sfvddff3
            - edd1c9f0985e76a1
--- exec
curl -k -s --resolve "test2.com:1994:127.0.0.1" https://test2.com:1994/hello 2>&1 | cat
--- response_body
hello world
