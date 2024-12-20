use t::APISIX 'no_plan';

no_long_string();
no_root_location();
run_tests;

__DATA__

=== TEST 1: add consumer with username and plugins
# in this test we configure another extra plugin `cors` which is not configured in the route
# to make APISIX think that there are some plugins that need to be executed in the rewrite
# phase.

# `cors` plugin is chosen for the simplicity of configuration
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "jack",
                    "plugins": {
                        "cors": {},
                        "key-auth": {
                            "key": "auth-one"
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
--- request
GET /t
--- response_body
passed



=== TEST 2: enable key auth and serverless-pre-function in route
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "key-auth": {},
                        "serverless-pre-function": {
                            "phase": "rewrite",
                            "functions": ["
                                return function(conf, ctx)
                                    ctx.count = (ctx.count or 0) + 1
                                    ngx.log(ngx.ERR, \"serverless pre function count: \", ctx.count);
                                end
                            "]
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
            end
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 3: valid consumer
--- request
GET /hello
--- more_headers
apikey: auth-one
--- response_body
hello world
--- no_error_log
func(): serverless pre function count: 2
