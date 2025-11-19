use t::APISIX 'no_plan';

repeat_each(1);
log_level('info');
no_long_string();
no_root_location();

add_block_preprocessor(sub {
    my ($block) = @_;
    my $extra_init_by_lua_start = <<_EOC_;
require "agent.hook";
_EOC_

    $block->set_value("extra_init_by_lua_start", $extra_init_by_lua_start);

    my $extra_init_by_lua = <<_EOC_;
    local server = require("lib.server")
    local core = require("apisix.core")
    server.api_dataplane_heartbeat = function()
        ngx.say(core.json.encode({}))
    end

    server.api_dataplane_developer_query = function()
        local plugin_name = ngx.var.arg_plugin_name
        local key_value = ngx.var.arg_key_value
        local portal_id = ngx.var.arg_portal_id
        local api_product_id = ngx.var.arg_api_product_id

        ngx.log(ngx.INFO, "receive data plane developer_query: ", plugin_name, ", ", key_value,
                                ", ", portal_id, ", ", api_product_id)

        local mock_data = {
            ["key-auth"] = {
                ["jack"] = {
                    credential_id = "jack",
                    consumer_name = "jack",
                    username = "jack",
                    modifiedIndex = 111
                }
            },
            ["basic-auth"] = {
                ["rose"] = {
                    credential_id = "rose",
                    consumer_name = "rose",
                    username = "rose",
                    auth_conf = {
                        username = "rose",
                        password = "123456"
                    },
                    modifiedIndex = 111
                }
            },
            ["oidc"] = {
                ["course_management"] = {
                    credential_id = "course_management",
                    consumer_name = "course_management",
                    username = "course_management",
                    modifiedIndex = 111
                }
            },
        }

        local payload = mock_data[plugin_name] and mock_data[plugin_name][key_value]
        if not payload then
            return ngx.exit(404)
        end

        ngx.say(core.json.encode(payload))
    end

_EOC_

    $block->set_value("extra_init_by_lua", $extra_init_by_lua);

    if (!$block->request) {
        if (!$block->stream_request) {
            $block->set_value("request", "GET /t");
        }
    }

    my $extra_yaml_config = <<_EOC_;
api7ee:
  telemetry:
    enable: false
_EOC_

    $block->set_value("extra_yaml_config", $extra_yaml_config);

    if ((!defined $block->error_log) && (!defined $block->no_error_log)) {
        $block->set_value("no_error_log", "[error]");
    }
});

run_tests;

__DATA__

=== TEST 1: invalid case expression
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "methods": ["GET"],
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1981": 1
                        },
                        "type": "roundrobin"
                    },
                    "plugins":{
                        "portal-auth": {
                            "rules": [
                                {
                                    "portal_id": "uat",
                                    "api_product_id": "uat-httpbin",
                                    "case": [ [] ],
                                    "auth_plugins": [
                                        {
                                            "basic-auth": {}
                                        }
                                    ]
                                }
                            ]
                        }
                    },
                    "uri": "/hello"
                }]]
                )

            ngx.status = code
            ngx.print(body)
        }
    }
--- request
GET /t
--- error_code: 400
--- response_body
{"error_msg":"failed to check the configuration of plugin portal-auth err: failed to validate the 1th case: rule too short"}



=== TEST 2: configure auth_plugins and rules at the same time
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "methods": ["GET"],
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1981": 1
                        },
                        "type": "roundrobin"
                    },
                    "plugins":{
                        "portal-auth": {
                            "auth_plugins": [
                                {
                                    "key-auth": {}
                                }
                            ],
                            "rules": [
                                {
                                    "portal_id": "uat",
                                    "api_product_id": "uat-httpbin",
                                    "case": [ [] ],
                                    "auth_plugins": [
                                        {
                                            "basic-auth": {}
                                        }
                                    ]
                                }
                            ]
                        }
                    },
                    "uri": "/hello"
                }]]
                )

            ngx.status = code
            ngx.print(body)
        }
    }
--- request
GET /t
--- error_code: 400
--- response_body
{"error_msg":"failed to check the configuration of plugin portal-auth err: value should match only one schema, but matches both schemas 1 and 2"}



=== TEST 3: enable key-auth, basic-auth, oidc with different conditions
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "methods": ["GET"],
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1981": 1
                        },
                        "type": "roundrobin"
                    },
                    "plugins":{
                        "portal-auth": {
                            "rules": [
                                {
                                    "portal_id": "dev",
                                    "api_product_id": "dev-httpbin",
                                    "case": [ ["http_host", "==", "dev.httpbin.dev"] ],
                                    "auth_plugins": [
                                        {
                                            "key-auth": {}
                                        }
                                    ]
                                },
                                {
                                    "portal_id": "uat",
                                    "api_product_id": "uat-httpbin",
                                    "case": [ ["http_host", "==", "uat.httpbin.dev"] ],
                                    "auth_plugins": [
                                        {
                                            "basic-auth": {}
                                        }
                                    ]
                                },
                                {
                                    "portal_id": "prod",
                                    "api_product_id": "prod-httpbin",
                                    "case": [ ["http_host", "==", "prod.httpbin.dev"] ],
                                    "auth_plugins": [
                                        {
                                            "oidc": {
                                                "discovery": "http://127.0.0.1:8080/realms/University/.well-known/openid-configuration"
                                            }
                                        }
                                    ]
                                }
                            ]
                        }
                    },
                    "uri": "/hello",
                    "labels": {
                        "portal:dcr:require_any_scopes": "phone address"
                    }
                }]]
                )

            if code <= 201 then
                ngx.status = 200
            end

            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 4: request with wrong key-auth to dev.httpbin.dev
--- request
GET /hello
--- more_headers
apikey: wrongkey
host: dev.httpbin.dev
--- error_code: 401
--- error_log
receive data plane developer_query: key-auth, wrongkey, dev, dev-httpbin



=== TEST 5: request with right key-auth to dev.httpbin.dev
--- request
GET /hello
--- more_headers
apikey: jack
host: dev.httpbin.dev
--- error_code: 200
--- response_body
hello world
--- error_log
receive data plane developer_query: key-auth, jack, dev, dev-httpbin



=== TEST 6: request with right basic-auth to uat.httpbin.dev
--- request
GET /hello
--- more_headers
Authorization: Basic Zm9vOmZvbwo=
host: uat.httpbin.dev
--- error_code: 401
--- error_log
receive data plane developer_query: basic-auth, foo, uat, uat-httpbin



=== TEST 7: request with right basic-auth to uat.httpbin.dev
--- request
GET /hello
--- more_headers
Authorization: Basic cm9zZToxMjM0NTY=
host: uat.httpbin.dev
--- error_code: 200
--- response_body
hello world
--- error_log
receive data plane developer_query: basic-auth, rose, uat, uat-httpbin



=== TEST 8: request without any auth to other.httpbin.dev
--- request
GET /hello
--- more_headers
host: other.httpbin.dev
--- error_code: 200
--- response_body
hello world
--- error_log
no matching auth rule found



=== TEST 9: send multiple requests to confirm every case compiled only once
--- log_level: debug
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.http"
            local httpc = http.new()

            for i = 1, 6 do
                local uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/hello"
                local res, err = httpc:request_uri(uri, {
                    method = "GET",
                    headers = {
                        ["Host"] = "other.httpbin.dev",
                    }
                 })

                if not res then
                    ngx.say(err)
                    ngx.exit(res.status)
                end

                if res.status ~= 200 then
                    ngx.say("unexpected response, status: ", res.status, ", body: ", res.body)
                    ngx.exit(res.status)
                end
            end

            ngx.say("passed")
        }
    }
--- error_code: 200
--- response_body
passed
--- grep_error_log eval
qr/compiling case expression for portal auth rule.*/
--- grep_error_log_out
compiling case expression for portal auth rule, case: [["http_host","==","dev.httpbin.dev"]]
compiling case expression for portal auth rule, case: [["http_host","==","uat.httpbin.dev"]]
compiling case expression for portal auth rule, case: [["http_host","==","prod.httpbin.dev"]]



=== TEST 10: request without access token to prod.httpbin.dev
--- request
GET /hello
--- more_headers
host: prod.httpbin.dev
--- error_code: 401
--- error_log
no Authorization header found
--- response_body
{"message":"Authorization Failed"}



=== TEST 11: request with access token to prod.httpbin.dev
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local util = require("apisix.cli.util")
            local json_decode = require("toolkit.json").decode
            local http = require "resty.http"
            local httpc = http.new()

            local get_token = function(scope)
                local uri = "http://127.0.0.1:8080/realms/University/protocol/openid-connect/token"
                local res, err = httpc:request_uri(uri, {
                        method = "POST",
                        body = core.string.encode_args({
                            grant_type = "password",
                            client_id = "course_management",
                            client_secret = "d1ec69e9-55d2-4109-a3ea-befa071579d5",
                            username = "teacher@gmail.com",
                            password = "123456",
                            scope = scope,
                        }),
                        headers = {
                            ["Content-Type"] = "application/x-www-form-urlencoded"
                        }
                    })

                if not res then
                    ngx.say("failed to request keycloak, err: ", err)
                    ngx.exit(500)
                end

                if res.status ~= 200 then
                    ngx.say("failed to get access token, status: ", res.status, ", body: ", res.body)
                    ngx.exit(500)
                end

                local body = json_decode(res.body)
                return body["access_token"]
            end

            local send_request = function(token, code, body)
                local uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/hello"
                local res, err = httpc:request_uri(uri, {
                    method = "GET",
                    headers = {
                        ["Host"] = "prod.httpbin.dev",
                        ["Authorization"] = "Bearer " .. token
                    }
                 })

                if not res then
                    ngx.say(err)
                    ngx.exit(res.status)
                end

                if res.status ~= code then
                    ngx.say("unexpected response, status: ", res.status, ", body: ", res.body)
                    ngx.exit(res.status)
                end
            end

            -- miss all required scopes
            send_request(get_token("email"), 401)
            -- miss part of required scopes
            send_request(get_token("phone"), 200)
            -- have all required scopes
            send_request(get_token("phone address"), 200)

            ngx.say("passed")
        }
    }
--- error_code: 200
--- response_body
passed
--- error_log
receive data plane developer_query: oidc, course_management, prod, prod-httpbin
Insufficient scopes in access token
