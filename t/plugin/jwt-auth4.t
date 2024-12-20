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

repeat_each(2);
no_long_string();
no_root_location();
no_shuffle();
log_level("debug");

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!defined $block->request) {
        $block->set_value("request", "GET /t");
    }
});

run_tests;

__DATA__

=== TEST 1: add consumer with username and plugins
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
                            "secret": "my-secret-key",
                            "algorithm": "HS384"
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



=== TEST 2: enable jwt auth plugin using admin api
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "jwt-auth": {}
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
--- response_body
passed



=== TEST 3: create public API route (jwt-auth sign)
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



=== TEST 4: sign / verify in argument
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, err, sign = t('/apisix/plugin/jwt/sign?key=user-key',
                ngx.HTTP_GET
            )

            if code > 200 then
                ngx.status = code
                ngx.say(err)
                return
            end

            local code, _, res = t('/hello?jwt=' .. sign,
                ngx.HTTP_GET
            )

            ngx.status = code
            ngx.print(res)
        }
    }
--- response_body
hello world
--- error_log
"alg":"HS384"



=== TEST 5: verify: invalid JWT token
--- request
GET /hello?jwt=invalid-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJrZXkiOiJ1c2VyLWtleSIsImV4cCI6MTU2Mzg3MDUwMX0.pPNVvh-TQsdDzorRwa-uuiLYiEBODscp9wv0cwD6c68
--- error_code: 401
--- response_body
{"message":"JWT token invalid"}
--- error_log
JWT token invalid: invalid header: invalid-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9



=== TEST 6: verify token with algorithm HS256
--- request
GET /hello
--- more_headers
Authorization: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJrZXkiOiJ1c2VyLWtleSIsImV4cCI6MTg3OTMxODU0MX0.fNtFJnNmJgzbiYmGB0Yjvm-l6A6M4jRV1l4mnVFSYjs
--- response_body
hello world
--- error_log
"alg":"HS256"



=== TEST 7: missing public key and private key
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
                            "secret": "my-secret-key",
                            "algorithm": "PS256"
                        }
                    }
                }]]
                )

            if code >= 300 then
                ngx.status = code
            end
            ngx.print(body)
        }
    }
--- error_code: 400
--- response_body
{"error_msg":"invalid plugins configuration: failed to check the configuration of plugin jwt-auth err: failed to validate dependent schema for \"algorithm\": value should match only one schema, but matches none"}



=== TEST 8: missing public key and private key
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
                            "key": "user-key2",
                            "secret": "my-secret-key",
                            "algorithm": "PS256",
                            "public_key": "-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAiSpoCgu3GzeExroi2YQ+\nxcQlXqEO8D5/5DgrlGsEb3Y9kEX+lj3ayW/G93nAob1xrtpjzBLf4chDivcmMj1q\nOwggoAOOmC9D/EYzDNKAos/gNcgsxra1X7xdMje+jUYR8nQGLemkidD71XbOrrcy\nLTE886t/lcrauC3dxNl55DkZc22YZWSanmizGfedMIEVtZb08uXbTi+8KyP3d+QL\nKYQ2eSa8AQredrKmM0eREQHr6R+zz6xqgycJ/Pxp+C0UYFbV+LVnHom5u6ck2SNG\nuGI1sBQ3V763BArbGpWlpcetQT5JB8QDhywf1ihNdaJgWhswQJVSMpJ8ZmA8R1Av\nDQIDAQAB\n-----END PUBLIC KEY-----",
                            "private_key": "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCJKmgKC7cbN4TG\nuiLZhD7FxCVeoQ7wPn/kOCuUawRvdj2QRf6WPdrJb8b3ecChvXGu2mPMEt/hyEOK\n9yYyPWo7CCCgA46YL0P8RjMM0oCiz+A1yCzGtrVfvF0yN76NRhHydAYt6aSJ0PvV\nds6utzItMTzzq3+Vytq4Ld3E2XnkORlzbZhlZJqeaLMZ950wgRW1lvTy5dtOL7wr\nI/d35AsphDZ5JrwBCt52sqYzR5ERAevpH7PPrGqDJwn8/Gn4LRRgVtX4tWceibm7\npyTZI0a4YjWwFDdXvrcECtsalaWlx61BPkkHxAOHLB/WKE11omBaGzBAlVIyknxm\nYDxHUC8NAgMBAAECggEAOduFXxdp+TUF8L17Db1WrRz7llrhbj0uvRlkaIprqIh7\nl2uu47jbnLRlfOYCdzbtyQ+doOslPJu4wdlWZ0K4mIXpHRXjBBaL2tHRnsr8L7D3\npjf1iyxufR97QD97RSQVVevS33L6UJeyYmxm6hOkOqPWTgI9IvYaJC5UqUACxl0h\nY+QDTwcUloVBSZGCJf6S2MZLDX9vNPbxqBIodsozbvfUmKEk9vztysFwhfY1iL6x\naYqwhIs2kRxTn3fgL3KnwGuETpcwL3lALKxCe+YR2lmZiX2mWAupyIKaJdmwXAw/\nRn83pnRTsZ4gN//KuSgKC/pax+zsZy0aGDfOobSTkQKBgQC83MwYEHJGnJA+NzuX\n3surIO8g0e/UiJzYXlFL13vHiYNLe0dM3Lq6/NOG5StmgdmheakQbH5ddNXqhcLA\nSwqJNU9Fs0xDuitGDKcTj8aboEv3pUlEDKnblgQ1Gu7atRckXT6FaJXA6o+6IANF\n5hQ/tnRAQavjWVyvDYsDB0XivwKBgQC57QAwZzkxnfZQhVyaKP4MdkUvsxH8p88P\nORAB9rD+raRaX7kBpK84HJGi4p/uQ40/lG5I3OdYZaxQgwJmFIfvorhlsJ22dngp\nnjdOOEfCnLQntsnEO9alYiG9JVy5eiX3I/K+DMoT4h9mNd3iBy0x5p78H+HfkUwE\nC+DUHEO9MwKBgHbAfrRC4xfzKd9060u7E2Uu+C0y1BJXNAf4hjWh8HquxJeZlGOI\nBwG8J2UShA+YZjdaQCvLjElHRZqJMMOoa5+KnaW9755GWR9apVNve/ou+JVmoILh\nU4x2735UyQtMApki6EUKVd9Pnb/ykRxKZ0EIgGBG6sWxUs3fPiFRWWgRAoGBAIwj\nI9JX61cHneGBM5QKs7nG500VpsgN39a0hulD/JJpZQitP7AKZftgJTFlqXAYQH2c\nrieDQWhychfZN1SjwvYPavdS0Pz3fIi59Sui5gu8u1l3v8qF47qSJaYAZEx00ere\nkJdI4oNsG4iZr10vVZRYJJsamNA/HtGp9lNJ3pDbAoGAXdUwIgjbrUg0ifdyGumS\nc0V4gOp/csqfg1QCAcYlTGkQp4iYw+/TXpSqoqqfuZsNawjvA2nUZKszf7lLtG1V\n82PvUh91sZZAdkQxtfpi0Lh406MHUMSESe4pWI+2QNb6l1bKP50lX89L11jvGvzM\n2SDDdrgDtpoYRB56vlERhH8=\n-----END PRIVATE KEY-----"
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



=== TEST 9: sign / verify in argument
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, err, sign = t('/apisix/plugin/jwt/sign?key=user-key2',
                ngx.HTTP_GET
            )

            if code > 200 then
                ngx.status = code
                ngx.say(err)
                return
            end

            local code, _, res = t('/hello?jwt=' .. sign,
                ngx.HTTP_GET
            )

            ngx.status = code
            ngx.print(res)
        }
    }
--- response_body
hello world
--- error_log
"alg":"PS256"



=== TEST 10: verify token with algorithm PS356
--- request
GET /hello
--- more_headers
Authorization: eyJhbGciOiJQUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1c2VybmFtZSI6Ind3dy5iZWpzb24uY29tIiwic3ViIjoiZGVtbyIsImtleSI6InVzZXIta2V5MiIsImV4cCI6MjA4OTcyNDA1N30.cKaijeZ4ydKVKCC37UZObPFj_kVsdiScEuGwK_G9JBjg0dcRnL8Xvr6Ofp8kDJz16FO2vy8FHgA_9HVjVpzehNe-AbtYJ88Qopy2pAQHsottGuQe3jgAt-yBI5chf26GzpqTtyymteg-lt-cW6EoP4gVHfXEbzQaOZt0wmdNBX17jISKW70okdxrp7cJKbv4hXQXjhYwKY8h0jYnGb-RhuHXRwWFhp6TZVV57Lfpi1yUDm6GqXM42W7owOOwjUqS8-7KYv1iugQzTo7qcVjPic7X5Wug7N-4t8BRM9jZkUiNrAY2BoxxBMUUru4fd201KY23p4bZDwQFpg6MVck7XA
--- response_body
hello world



=== TEST 11: add consumer with username and plugins
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
                            "secret": "my-secret-key",
                            "algorithm": "HS384"
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



=== TEST 12: only verify nbf claim
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "jwt-auth": {
                            "claims_to_verify": ["nbf"]
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
--- response_body
passed



=== TEST 13: verify success with expired token
--- request
GET /hello
--- more_headers
Authorization: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJrZXkiOiJ1c2VyLWtleSIsImV4cCI6MTU2Mzg3MDUwMX0.pPNVvh-TQsdDzorRwa-uuiLYiEBODscp9wv0cwD6c68
--- response_body
hello world



=== TEST 14: verify failed before nbf claim
--- request
GET /hello
--- more_headers
Authorization: eyJhbGciOiJIUzM4NCIsInR5cCI6IkpXVCJ9.eyJrZXkiOiJ1c2VyLWtleSIsImV4cCI6MTU2Mzg3MDUwMSwibmJmIjoyMjI5NjcxODc0fQ.RJynr34TyCesYHwvDwOwETi1vOfZXKqc_wvQJ3pijBfrx1x5IF3O1CCUCvd5lMYf
--- error_code: 401
--- response_body eval
qr/failed to verify jwt/
--- error_log
'nbf' claim not valid until Mon, 27 Aug 2040 09:17:54 GMT



=== TEST 15: verify success after nbf claim
--- request
GET /hello
--- more_headers
Authorization: eyJhbGciOiJIUzM4NCIsInR5cCI6IkpXVCJ9.eyJrZXkiOiJ1c2VyLWtleSIsImV4cCI6MTU2Mzg3MDUwMSwibmJmIjoxNzI5Njc1MDQyfQ.IycpH4Lc48BHSxUBXBNDXGawvNgi_6a-qsa-xnhYFLooeWc8DyX8zLadvyEFpMPq
--- response_body
hello world



=== TEST 16: EdDSA algorithm
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
                            "secret": "my-secret-key",
                            "algorithm": "EdDSA",
                            "public_key": "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEA9PdGVALrrBX4oX5t9DKb5JHYx7XRb0RXU42r0FVO2sA=\n-----END PUBLIC KEY-----",
                            "private_key": "-----BEGIN PRIVATE KEY-----\nMC4CAQAwBQYDK2VwBCIEIKmBJXpq9Fp0K97TpJ2X9V6jszx23j7NtKKa6gZRaAjI\n-----END PRIVATE KEY-----"
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



=== TEST 17: sign / verify in argument
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, err, sign = t('/apisix/plugin/jwt/sign?key=user-key',
                ngx.HTTP_GET
            )

            if code > 200 then
                ngx.status = code
                ngx.say(err)
                return
            end

            local code, _, res = t('/hello?jwt=' .. sign,
                ngx.HTTP_GET
            )

            ngx.status = code
            ngx.print(res)
        }
    }
--- response_body
hello world
--- error_log
"alg":"EdDSA"
