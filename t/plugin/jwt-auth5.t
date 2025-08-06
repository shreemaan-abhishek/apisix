use t::APISIX 'no_plan';

no_long_string();
no_root_location();
no_shuffle();

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!defined $block->request) {
        $block->set_value("request", "GET /t");
    }
});

run_tests;

__DATA__

=== TEST 1: enable jwt auth plugin (with custom key_claim_name) using admin api
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/4',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "jwt-auth": {
                            "claims_to_verify": ["exp"],
                            "key": "custom-user-key",
                            "secret": "custom-secret-key",
                            "key_claim_name": "iss"
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
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 2: create public API route (jwt-auth sign)
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/2',
                 ngx.HTTP_PUT,
                 [[{
                        "plugins": {
                            "public-api": {}
                        },
                        "uri": "/apisix/plugin/jwt/sign"
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



=== TEST 3: verify that key_claim_name can be used to validate the Consumer JWT with a different claim than 'key'
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local t = require("lib.test_admin").test
            -- prepare consumer with a custom key claim name
            local csm_code, csm_body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "mike",
                    "plugins": {
                        "jwt-auth": {
                            "key": "custom-user-key",
                            "secret": "custom-secret-key"
                        }
                    }
                }]]
            )
            if csm_code >= 300 then
                ngx.status = csm_code
                ngx.say(csm_body)
                return
            end
            -- generate JWT with custom key ("key_claim_name" = "iss")
            local sign_code, sign_body, token = t('/apisix/plugin/jwt/sign?key=custom-user-key&key_claim_name=iss',
                ngx.HTTP_GET
            )
            if sign_code > 200 then
                ngx.status = sign_code
                ngx.say(sign_body)
                return
            end
            -- verify JWT using the custom key_claim_name
            local ver_code, ver_body = t('/hello?jwt=' .. token,
                ngx.HTTP_GET
            )
            if ver_code > 200 then
                ngx.status = ver_code
                ngx.say(ver_body)
                return
            end
            ngx.say("verified-jwt")
        }
    }
--- response_body
verified-jwt



=== TEST 4: ensure secret is non empty
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local t = require("lib.test_admin").test
            -- prepare consumer with a custom key claim name
            local csm_code, csm_body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "mike",
                    "plugins": {
                        "jwt-auth": {
                            "key": "custom-user-key",
                            "secret": ""
                        }
                    }
                }]]
            )
            if csm_code == 200 then
                ngx.status = 500
                ngx.say("error")
                return
            end
            ngx.status = csm_code
            ngx.say(csm_body)
        }
    }
--- error_code: 400
--- response_body eval
qr/\\"secret\\" validation failed: string too short, expected at least 1, got 0/



=== TEST 5: ensure key is non empty
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local t = require("lib.test_admin").test
            -- prepare consumer with a custom key claim name
            local csm_code, csm_body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "mike",
                    "plugins": {
                        "jwt-auth": {
                            "key": "",
                            "algorithm": "RS256",
                            "public_key": "somekey",
                            "private_key": "someprivkey"
                        }
                    }
                }]]
            )
            if csm_code == 200 then
                ngx.status = 500
                ngx.say("error")
                return
            end
            ngx.status = csm_code
            ngx.say(csm_body)
        }
    }
--- error_code: 400
--- response_body eval
qr/\\"key\\" validation failed: string too short, expected at least 1, got 0/



=== TEST 6: ensure public_key is non empty
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local t = require("lib.test_admin").test
            -- prepare consumer with a custom key claim name
            local csm_code, csm_body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "mike",
                    "plugins": {
                        "jwt-auth": {
                            "key": "sdfsd",
                            "algorithm": "RS256",
                            "public_key": "",
                            "private_key": "someprivkey"
                        }
                    }
                }]]
            )
            if csm_code == 200 then
                ngx.status = 500
                ngx.say("error")
                return
            end
            ngx.status = csm_code
            ngx.say(csm_body)
        }
    }
--- error_code: 400
--- response_body eval
qr/\\"algorithm\\": value should match only one schema, but matches none/



=== TEST 7: ensure private_key is non empty
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local t = require("lib.test_admin").test
            -- prepare consumer with a custom key claim name
            local csm_code, csm_body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "mike",
                    "plugins": {
                        "jwt-auth": {
                            "key": "key",
                            "algorithm": "RS256",
                            "public_key": "somekey",
                            "private_key": ""
                        }
                    }
                }]]
            )
            if csm_code == 200 then
                ngx.status = 500
                ngx.say("error")
                return
            end
            ngx.status = csm_code
            ngx.say(csm_body)
        }
    }
--- error_code: 400
--- response_body eval
qr/\\"algorithm\\": value should match only one schema, but matches none/



=== TEST 8: add consumer with user-key for store_in_ctx tests
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "jack",
                    "plugins": {
                        "jwt-auth": {
                            "key": "user-key",
                            "secret": "my-secret-key"
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
--- response_body
passed



=== TEST 9: store_in_ctx disabled
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "jwt-auth": {},
                        "serverless-post-function": {
                            "phase": "rewrite",
                            "functions": [
                                "return function(conf, ctx)
                                if ctx.jwt_auth_payload then
                                    ngx.status = 200
                                    ngx.say(\"JWT found in ctx. Payload key: \" .. ctx.jwt_auth_payload.key)
                                    return ngx.exit(200)
                                else
                                    ngx.status = 401
                                    ngx.say(\"JWT not found in ctx.\")
                                    return ngx.exit(401)
                                end
                                end"
                            ]
                        }
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    },
                    "uri": "/jwt-auth-no-ctx"
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



=== TEST 10: verify store_in_ctx disabled (header with bearer)
--- request
GET /jwt-auth-no-ctx
--- more_headers
Authorization: bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJrZXkiOiJ1c2VyLWtleSIsImV4cCI6MTg3OTMxODU0MSwibmJmIjoxNTc3ODM2ODAwfQ.8MuMWHphs7ot_AYtjcK7odE2JWbUY0f-gwCt7WGj_3E
--- error_code: 401
--- response_body
JWT not found in ctx.



=== TEST 11: store_in_ctx enabled
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/2',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "jwt-auth": {
                            "store_in_ctx": true
                        },
                        "serverless-post-function": {
                            "phase": "rewrite",
                            "functions": [
                                "return function(conf, ctx)
                                if ctx.jwt_auth_payload then
                                    ngx.status = 200
                                    ngx.say(\"JWT found in ctx. Payload key: \" .. ctx.jwt_auth_payload.key)
                                    return ngx.exit(200)
                                else
                                    ngx.status = 401
                                    ngx.say(\"JWT not found in ctx.\")
                                    return ngx.exit(401)
                                end
                                end"
                            ]
                        }
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    },
                    "uri": "/jwt-auth-ctx"
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



=== TEST 12: verify store_in_ctx enabled (header with bearer)
--- request
GET /jwt-auth-ctx
--- more_headers
Authorization: bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJrZXkiOiJ1c2VyLWtleSIsImV4cCI6MTg3OTMxODU0MSwibmJmIjoxNTc3ODM2ODAwfQ.8MuMWHphs7ot_AYtjcK7odE2JWbUY0f-gwCt7WGj_3E
--- error_code: 200
--- response_body
JWT found in ctx. Payload key: user-key
