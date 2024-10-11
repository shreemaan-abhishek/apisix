use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_shuffle();
no_root_location();

run_tests;

__DATA__


=== TEST 1: add consumer jack1
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "jack1",
                    "plugins": {
                        "key-auth": {
                            "key": "auth-one"
                        },
                        "echo":{"body": "before change"}
                    }
                }]]
                )
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 2: add route
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                        "uri": "/hello",
                        "upstream": {
                            "type": "roundrobin",
                            "nodes": {
                                "127.0.0.1:1980": 1
                            }
                        },
                        "plugins": {
                            "key-auth": {}
                        }
                }]]
                )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 3: verify 20 times
--- pipelined_requests eval
["GET /hello", "GET /hello", "GET /hello", "GET /hello","GET /hello", "GET /hello", "GET /hello", "GET /hello","GET /hello", "GET /hello", "GET /hello", "GET /hello","GET /hello", "GET /hello", "GET /hello", "GET /hello","GET /hello", "GET /hello", "GET /hello", "GET /hello"]
--- more_headers
apikey: auth-one
--- response_body eval
["before change","before change","before change","before change","before change","before change","before change","before change","before change","before change","before change","before change","before change","before change","before change","before change","before change","before change","before change","before change"]



=== TEST 4: modify consumer
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "jack1",
                    "plugins": {
                        "key-auth": {
                            "key": "auth-one"
                        },
                        "echo":{"body": "after change"}
                    }
                }]]
                )
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed




=== TEST 5: verify 20 times
--- pipelined_requests eval
["GET /hello", "GET /hello", "GET /hello", "GET /hello","GET /hello", "GET /hello", "GET /hello", "GET /hello","GET /hello", "GET /hello", "GET /hello", "GET /hello","GET /hello", "GET /hello", "GET /hello", "GET /hello","GET /hello", "GET /hello", "GET /hello", "GET /hello"]
--- more_headers
apikey: auth-one
--- response_body eval
["after change","after change","after change","after change","after change","after change","after change","after change","after change","after change","after change","after change","after change","after change","after change","after change","after change","after change","after change","after change"]
