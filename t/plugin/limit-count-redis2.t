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

    if (!$block->request) {
        $block->set_value("request", "GET /t");
    }

    if (!$block->error_log && !$block->no_error_log) {
        $block->set_value("no_error_log", "[error]\n[alert]");
    }
});

run_tests;

__DATA__

=== TEST 1: set route, with redis host and port and default database
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/hello",
                    "plugins": {
                        "limit-count": {
                            "count": 2,
                            "time_window": 60,
                            "rejected_code": 503,
                            "key": "remote_addr",
                            "policy": "redis",
                            "redis_host": "127.0.0.1",
                            "redis_port": 6379,
                            "redis_timeout": 1001
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

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 2: set route, with redis host and port but wrong database
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/hello",
                    "plugins": {
                        "limit-count": {
                            "count": 2,
                            "time_window": 60,
                            "rejected_code": 503,
                            "key": "remote_addr",
                            "policy": "redis",
                            "redis_host": "127.0.0.1",
                            "redis_port": 6379,
                            "redis_database": 999999,
                            "redis_timeout": 1001
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

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 3: use wrong database
--- request
GET /hello
--- error_code eval
500
--- error_log
failed to limit count: failed to change redis db, err: ERR DB index is out of range



=== TEST 4: set route, with redis host and port and right database
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/hello",
                    "plugins": {
                        "limit-count": {
                            "count": 2,
                            "time_window": 60,
                            "rejected_code": 503,
                            "key": "remote_addr",
                            "policy": "redis",
                            "redis_host": "127.0.0.1",
                            "redis_port": 6379,
                            "redis_database": 1,
                            "redis_timeout": 1001
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

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 5: up the limit
--- pipelined_requests eval
["GET /hello", "GET /hello", "GET /hello", "GET /hello"]
--- error_code eval
[200, 200, 503, 503]



=== TEST 6: set route, with redis host but wrong port, with enable degradation switch
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/hello",
                    "plugins": {
                        "limit-count": {
                            "count": 2,
                            "time_window": 60,
                            "rejected_code": 503,
                            "key": "remote_addr",
                            "policy": "redis",
                            "allow_degradation": true,
                            "redis_host": "127.0.0.1",
                            "redis_port": 16379,
                            "redis_database": 1,
                            "redis_timeout": 1001
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

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 7: enable degradation switch for TEST 6
--- request
GET /hello
--- response_body
hello world
--- error_log
connection refused



=== TEST 8: set route, with don't show limit quota header
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/hello",
                    "plugins": {
                        "limit-count": {
                            "count": 2,
                            "time_window": 60,
                            "rejected_code": 503,
                            "key": "remote_addr",
                            "policy": "redis",
                            "show_limit_quota_header": false,
                            "redis_host": "127.0.0.1",
                            "redis_port": 6379,
                            "redis_database": 1,
                            "redis_timeout": 1001
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

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 9: don't show limit quota header for TEST 8
--- request
GET /hello
--- raw_response_headers_unlike eval
qr/X-RateLimit-Limit/



=== TEST 10: different configurations from the same group
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/hello",
                    "plugins": {
                        "limit-count": {
                            "count": 2,
                            "time_window": 60,
                            "rejected_code": 503,
                            "key": "remote_addr",
                            "policy": "redis",
                            "show_limit_quota_header": false,
                            "redis_host": "127.0.0.1",
                            "redis_port": 6379,
                            "redis_database": 1,
                            "redis_timeout": 1001,
                            "group": "redis"
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

            if code >= 300 then
                ngx.status = code
                return
            end

            local code, body = t('/apisix/admin/routes/2',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/hello1",
                    "plugins": {
                        "limit-count": {
                            "count": 3,
                            "time_window": 60,
                            "rejected_code": 503,
                            "key": "remote_addr",
                            "policy": "redis",
                            "show_limit_quota_header": false,
                            "redis_host": "127.0.0.1",
                            "redis_port": 6379,
                            "redis_database": 2,
                            "redis_timeout": 1001,
                            "group": "redis"
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

            if code >= 300 then
                ngx.status = code
                return
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 11: /hello and /hello1 not share the limit count
--- config
    location /t {
        content_by_lua_block {
            local json = require "t.toolkit.json"
            local http = require "resty.http"
            local uri1 = "http://127.0.0.1:" .. ngx.var.server_port
                        .. "/hello"
            local uri2 = "http://127.0.0.1:" .. ngx.var.server_port
                        .. "/hello1"
            local send_requests = function(count, uri)
                local ress = {}
                local httpc = http.new()
                for i = 1, count do
                    local res, err = httpc:request_uri(uri)
                    if not res then
                        ngx.say(err)
                        return
                    end
                    table.insert(ress, res.status)
                end
                return ress
            end

            ngx.say(json.encode(send_requests(5, uri1)))
            ngx.say(json.encode(send_requests(5, uri2)))
        }
    }
--- response_body
[200,200,503,503,503]
[200,200,200,503,503]



=== TEST 12: multiple configurations for the same group
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/hello",
                    "plugins": {
                        "limit-count": {
                            "count": 2,
                            "time_window": 60,
                            "rejected_code": 503,
                            "key": "remote_addr",
                            "policy": "redis",
                            "show_limit_quota_header": false,
                            "redis_host": "127.0.0.1",
                            "redis_port": 6379,
                            "redis_database": 1,
                            "redis_timeout": 1001,
                            "group": "redis2"
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

            if code >= 300 then
                ngx.status = code
                return
            end

            local code, body = t('/apisix/admin/routes/2',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/hello1",
                    "plugins": {
                        "limit-count": {
                            "count": 3,
                            "time_window": 60,
                            "rejected_code": 503,
                            "key": "remote_addr",
                            "policy": "redis",
                            "show_limit_quota_header": false,
                            "redis_host": "127.0.0.1",
                            "redis_port": 6379,
                            "redis_database": 2,
                            "redis_timeout": 1001,
                            "group": "redis2"
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

            if code >= 300 then
                ngx.status = code
                return
            end

            local code, body = t('/apisix/admin/routes/3',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/hello_chunked",
                    "plugins": {
                        "limit-count": {
                            "count": 2,
                            "time_window": 60,
                            "rejected_code": 503,
                            "key": "remote_addr",
                            "policy": "redis",
                            "show_limit_quota_header": false,
                            "redis_host": "127.0.0.1",
                            "redis_port": 6379,
                            "redis_database": 1,
                            "redis_timeout": 1001,
                            "group": "redis2"
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

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 13: /hello and /hello_chunked share the limit count, but /hello1 not
--- config
    location /t {
        content_by_lua_block {
            local json = require "t.toolkit.json"
            local http = require "resty.http"
            local uri1 = "http://127.0.0.1:" .. ngx.var.server_port
                        .. "/hello"
            local uri2 = "http://127.0.0.1:" .. ngx.var.server_port
                        .. "/hello1"
            local uri3 = "http://127.0.0.1:" .. ngx.var.server_port
                        .. "/hello_chunked"
            local send_requests = function(count, uri)
                local ress = {}
                local httpc = http.new()
                for i = 1, count do
                    local res, err = httpc:request_uri(uri)
                    if not res then
                        ngx.say(err)
                        return
                    end
                    table.insert(ress, res.status)
                end
                return ress
            end

            ngx.say(json.encode(send_requests(5, uri1)))
            ngx.say(json.encode(send_requests(5, uri2)))
            -- share the limit count with uri1
            ngx.say(json.encode(send_requests(5, uri3)))
        }
    }
--- response_body
[200,200,503,503,503]
[200,200,200,503,503]
[503,503,503,503,503]
