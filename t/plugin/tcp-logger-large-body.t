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

    $block->set_value("stream_conf_enable", 1);

    if (!defined $block->extra_stream_config) {
        my $stream_config = <<_EOC_;
    server {
        listen 8125;
        content_by_lua_block {
         local sock, err = ngx.req.socket()
            if not sock then
                ngx.log(ngx.ERR, "failed to get socket: ", err)
                return
            end
            
            sock:settimeout(5000)
            
            local data, err, partial = sock:receive("*a")
            if not data and not partial then
                ngx.log(ngx.ERR, "failed to receive data: ", err)
                return
            end
            
            local received_data = data or partial
            local body_size = #received_data
            
            ngx.log(ngx.INFO, "body_size >= 2MB: ", body_size >= 2 * 1024 * 1024)
        }
    }
_EOC_
        $block->set_value("extra_stream_config", $stream_config);
    }

});

run_tests;

__DATA__

=== TEST 1: add plugin
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                        "plugins": {
                            "tcp-logger": {
                                "host": "127.0.0.1",
                                "port": 8125,
                                "tls": false,
                                "batch_max_size": 1,
                                "inactive_timeout": 1,
                                "include_req_body": true,
                                "max_req_body_bytes": 20649728
                            }
                        },
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
                ngx.say(body)
                return
            end

            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 2: send large body
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local t    = require("lib.test_admin")
            local http = require("resty.http")

            local large_body = {
                "h", "e", "l", "l", "o"
            }

            local size_in_bytes = 2 * 1024 * 1024 -- 2MB
            for i = 1, size_in_bytes do
                large_body[i+5] = "l"
            end
            large_body = table.concat(large_body, "")

            local uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/hello"

            local httpc = http.new()
            local res, err = httpc:request_uri(uri,
                {
                    method = "POST",
                    body = large_body,
                }
            )
            ngx.print(res.body)
        }
    }
--- request
GET /t
--- response_body
hello world
--- error_log
body_size >= 2MB: true
--- no_error_log
fail to get request body: fail to open file
