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
    $ENV{VAULT_TOKEN} = "root";
}

use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_root_location();
no_shuffle();
log_level("info");

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!$block->request) {
        $block->set_value("request", "GET /t");
    }

    if (!$block->no_error_log && !$block->error_log) {
        $block->set_value("no_error_log", "[error]\n[alert]");
    }
});

run_tests;

__DATA__

=== TEST 1: store secret into vault
--- exec
VAULT_TOKEN='root' VAULT_ADDR='http://0.0.0.0:8200' vault kv put kv/jack/key-auth key=ydz4ZVA4nug
VAULT_TOKEN='root' VAULT_ADDR='http://0.0.0.0:8200' vault kv put kv/rose/key-auth key=vjm6BXK
--- response_body
Success! Data written to: kv/jack/key-auth
Success! Data written to: kv/rose/key-auth



=== TEST 2: prepare route, secret, consumer and key-auth plugin
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            -- add vault
            local code, body = t('/apisix/admin/secrets/vault/jack_test',
                ngx.HTTP_PUT,
                [[{
                    "uri": "http://127.0.0.1:8200",
                    "prefix" : "kv/jack",
                    "token" : "$ENV://VAULT_TOKEN"
                }]]
            )
            if code >= 300 then
                ngx.status = code
                return ngx.say(body)
            end

            -- add consumer
            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                     "username":"jack",
                     "desc": "new consumer",
                     "plugins": {
                        "key-auth": {
                            "key": "$secret://vault/jack_test/key-auth/key"
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                return ngx.say(body)
            end

            -- add route
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "uri": "/hello",
                    "plugins": {
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
                return ngx.say(body)
            end
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 3: change secret prefix in secret, only new key-auth key can fetch route
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/secrets/vault/jack_test',
                ngx.HTTP_PUT,
                [[{
                    "uri": "http://127.0.0.1:8200",
                    "prefix" : "kv/rose",
                    "token" : "$ENV://VAULT_TOKEN"
                }]]
            )
            ngx.status = code
            ngx.say(body)
        }
    }
--- pipelined_requests eval
["GET /hello", "GET /hello", "GET /t",
 "GET /hello", "GET /hello", "GET /hello"]
--- more_headers eval
["", "apikey: ydz4ZVA4nug", "", "", "apikey: ydz4ZVA4nug", "apikey: vjm6BXK"]
--- error_code eval
[401, 200, 200, 401, 401, 200]
--- response_body eval
[qr/{\"message\":\"Missing API key found in request\"}/, qr/hello world/, qr/passed/,
qr/{\"message\":\"Missing API key found in request\"}/, qr/{\"message\":\"Invalid API key in request\"}/, qr/hello world/]
