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

=== TEST 1: sanity
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin")
            local plugin = require("apisix.plugins.oas-validator")
            local ospec = t.read_file("t/spec/spec.json")

            local ok, err = plugin.check_schema({spec = ospec})
            if not ok then
                ngx.say(err)
            end

            ngx.say("done")
        }
    }
--- response_body
done



=== TEST 2: open api string should be json
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.oas-validator")
            local ok, err = plugin.check_schema({spec = "invalid json string"})
            ngx.say(err)
        }
    }
--- response_body
invalid JSON string provided, err: Expected value but found invalid token at character 1



=== TEST 3: create route correctly
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin")
            local spec = t.read_file("t/spec/spec.json")
            spec = spec:gsub('\"', '\\"')

            local code, body = t.test('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 string.format([[{
                     "uri": "/*",
                     "plugins": {
                       "oas-validator": {
                         "spec": "%s"
                       }
                     },
                     "upstream": {
                       "type": "roundrobin",
                       "nodes": {
                         "127.0.0.1:6969": 1
                       }
                     }
                }]], spec)
                )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 4: test body validation -- POST
--- request
POST /api/v3/pet
{"id": 10, "name": "doggie", "category": {"id": 1, "name": "Dogs"}, "photoUrls": ["string"], "tags": [{"id": 1, "name": "tag1"}], "status": "available"}
--- more_headers
Content-Type: application/json
--- no_error_log
[error]



=== TEST 5: test body validation -- PUT
--- request
PUT /api/v3/pet
{"id": 10, "name": "doggie", "category": { "id": 1, "name": "Dogs"}, "photoUrls": [ "string"], "tags": [{ "id": 0, "name": "string"}], "status": "available"}
--- more_headers
Content-Type: application/json
--- no_error_log
[error]



=== TEST 6: passing incorrect body should fail
--- request
POST /api/v3/pet
{"lol": "watdis?"}
--- more_headers
Content-Type: application/json
--- response_body_like: failed to validate request.
--- error_code: 400
--- error_log
error occured while validating request



=== TEST 7: test body validation with Query Params
--- request
GET /api/v3/pet/findByStatus?status=pending
--- more_headers
Content-Type: application/json
--- no_error_log
[error]



=== TEST 8: querying for married dogs should fail (incorrect query param)
--- request
GET /api/v3/pet/findByStatus?status=married
--- more_headers
Content-Type: application/json
--- response_body_like: failed to validate request.
--- error_code: 400
--- error_log
error occured while validating request



=== TEST 9: test body validation with Path Params
--- request
GET /api/v3/pet/10
--- more_headers
Content-Type: application/json
--- no_error_log
[error]



=== TEST 10: querying with wrong path uri param should fail
--- request
GET /api/v3/pet/wrong-id
--- more_headers
Content-Type: application/json
--- response_body_like: failed to validate request.
--- error_code: 400
--- error_log
error occured while validating request



=== TEST 11: create route for skipping body validation
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin")
            local spec = t.read_file("t/spec/spec.json")
            spec = spec:gsub('\"', '\\"')

            local code, body = t.test('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 string.format([[{
                     "uri": "/*",
                     "plugins": {
                       "oas-validator": {
                         "spec": "%s",
                         "skip_request_body_validation": true
                       }
                     },
                     "upstream": {
                       "type": "roundrobin",
                       "nodes": {
                         "mock.api7.ai:443": 1
                       },
                       "scheme": "https",
                       "pass_host": "node"
                     }
                }]], spec)
                )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 12: passing incorrect body should pass validation (skip_request_body_validation = false)
--- request
POST /api/v3/pet
{"lol": "watdis?"}
--- more_headers
Content-Type: application/json
--- no_error_log
[error]



=== TEST 13: create route for skipping header validation
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin")
            local spec = t.read_file("t/spec/spec.json")
            spec = spec:gsub('\"', '\\"')

            local code, body = t.test('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 string.format([[{
                     "uri": "/*",
                     "plugins": {
                       "oas-validator": {
                         "spec": "%s",
                         "skip_request_header_validation": true
                       }
                     },
                     "upstream": {
                       "type": "roundrobin",
                       "nodes": {
                         "mock.api7.ai:443": 1
                       },
                       "scheme": "https",
                       "pass_host": "node"
                     }
                }]], spec)
                )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 14: passing incorrect header should pass validation (skip_request_header_validation = false)
--- request
GET /api/v3/pet/1
--- more_headers
Content-Type: not-application/json
--- error_code: 200



=== TEST 15: create route for skipping query param validation
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin")
            local spec = t.read_file("t/spec/spec.json")
            spec = spec:gsub('\"', '\\"')

            local code, body = t.test('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 string.format([[{
                     "uri": "/*",
                     "plugins": {
                       "oas-validator": {
                         "spec": "%s",
                         "skip_query_param_validation": true
                       }
                     },
                     "upstream": {
                       "type": "roundrobin",
                       "nodes": {
                         "mock.api7.ai:443": 1
                       },
                       "scheme": "https",
                       "pass_host": "node"
                     }
                }]], spec)
                )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 16: querying for incorrect query params should pass (validate_request_query_params = false)
--- request
GET /api/v3/pet/findByStatus?status=married
--- more_headers
Content-Type: application/json
--- error_code: 200



=== TEST 17: create route for skipping path param validation
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin")
            local spec = t.read_file("t/spec/spec.json")
            spec = spec:gsub('\"', '\\"')

            local code, body = t.test('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 string.format([[{
                     "uri": "/*",
                     "plugins": {
                       "oas-validator": {
                         "spec": "%s",
                         "skip_path_params_validation": true
                       }
                     },
                     "upstream": {
                       "type": "roundrobin",
                       "nodes": {
                         "mock.api7.ai:443": 1
                       },
                       "scheme": "https",
                       "pass_host": "node"
                     }
                }]], spec)
                )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 18: querying for incorrect path params should pass (skip_path_params_validation = true)
--- request
GET /api/v3/pet/incorrect-id
--- more_headers
Content-Type: application/json
--- error_code: 200



=== Test 19: test multipleOf validation
--- request
POST /api/v3/multipleoftest
{"testnumber": 1.13}
--- more_headers
Content-Type: application/json
--- no_error_log
[error]



=== Test 20: test multipleOf validation - invalid
--- request
POST /api/v3/multipleoftest
{"testnumber": 1.1312}
--- more_headers
Content-Type: application/json
--- response_body_like: failed to validate request.
--- error_code: 400
--- error_log
error occured while validating request
