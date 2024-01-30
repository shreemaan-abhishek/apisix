use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_shuffle();
no_root_location();

run_tests;

__DATA__

=== TEST 1: add consumer jack
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "jack",
                    "plugins": {
                        "basic-auth": {
                            "username": "jack",
                            "password": "123456"
                        }
                    },
                    "labels": {
                        "org": "apache",
                        "project": "gateway,apisix,web-server"
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



=== TEST 2: add consumer rose
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "rose",
                    "plugins": {
                        "basic-auth": {
                            "username": "rose",
                            "password": "123456"
                        }
                    },
                    "labels": {
                        "org": "opensource,apache",
                        "project": "tomcat,web-server"
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



=== TEST 3: set allow_labels
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
                            "basic-auth": {},
                            "acl": {
                                 "allow_labels": {
                                    "org": ["apache"]
                                 }
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



=== TEST 4: verify unauthorized
--- request
GET /hello
--- error_code: 401
--- response_body
{"message":"Missing authorization in request"}



=== TEST 5: verify jack
--- request
GET /hello
--- more_headers
Authorization: Basic amFjazoxMjM0NTY=
--- response_body
hello world



=== TEST 6: verify rose
--- request
GET /hello
--- more_headers
Authorization: Basic cm9zZToxMjM0NTY=
--- response_body
hello world



=== TEST 7: set allow_labels
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
                            "basic-auth": {},
                            "acl": {
                                 "allow_labels": {
                                     "project": ["apisix"]
                                 }
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



=== TEST 8: verify jack
--- request
GET /hello
--- more_headers
Authorization: Basic amFjazoxMjM0NTY=
--- response_body
hello world



=== TEST 9: verify rose
--- request
GET /hello
--- more_headers
Authorization: Basic cm9zZToxMjM0NTY=
--- error_code: 403
--- response_body
{"message":"The consumer is forbidden."}



=== TEST 10: set deny_labels
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
                            "basic-auth": {},
                            "acl": {
                                 "deny_labels": {
                                     "project": ["apisix"]
                                 },
                                 "rejected_msg": "request is forbidden"
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



=== TEST 11: verify jack
--- request
GET /hello
--- more_headers
Authorization: Basic amFjazoxMjM0NTY=
--- error_code: 403
--- response_body
{"message":"request is forbidden"}



=== TEST 12: verify rose
--- request
GET /hello
--- more_headers
Authorization: Basic cm9zZToxMjM0NTY=
--- response_body
hello world



=== TEST 13: set deny_labels with multiple values
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
                            "basic-auth": {},
                            "acl": {
                                 "deny_labels": {
                                     "project": ["apisix", "tomcat"]
                                 }
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



=== TEST 14: verify jack
--- request
GET /hello
--- more_headers
Authorization: Basic amFjazoxMjM0NTY=
--- error_code: 403



=== TEST 15: verify rose
--- request
GET /hello
--- more_headers
Authorization: Basic cm9zZToxMjM0NTY=
--- error_code: 403



=== TEST 16: delete route
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t( '/apisix/admin/routes/1', ngx.HTTP_DELETE )

            ngx.status = code
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 17: delete jack
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t( '/apisix/admin/consumers/jack', ngx.HTTP_DELETE )

            ngx.status = code
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 18: delete rose
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t( '/apisix/admin/consumers/rose', ngx.HTTP_DELETE )

            ngx.status = code
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed
