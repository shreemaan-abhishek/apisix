use t::APISIX 'no_plan';

repeat_each(1);
log_level('debug');
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
    server.api_dataplane_heartbeat = function()
        ngx.req.read_body()
        local data = ngx.req.get_body_data()
        ngx.log(ngx.NOTICE, "receive data plane heartbeat: ", data)

        local json_decode = require("toolkit.json").decode
        local payload = json_decode(data)

        if not payload.instance_id then
            ngx.log(ngx.ERR, "missing instance_id")
            return ngx.exit(400)
        end
        if not payload.hostname then
            ngx.log(ngx.ERR, "missing hostname")
            return ngx.exit(400)
        end
        if not payload.ip then
            ngx.log(ngx.ERR, "missing ip")
            return ngx.exit(400)
        end
        if not payload.version then
            ngx.log(ngx.ERR, "missing version")
            return ngx.exit(400)
        end
        if not payload.control_plane_revision then
            ngx.log(ngx.ERR, "missing control_plane_revision")
            return ngx.exit(400)
        end
        if not payload.ports then
            ngx.log(ngx.ERR, "missing ports")
            return ngx.exit(400)
        end

        local resp_payload = {
            config = {
                config_version = 1,
                config_payload = {
                    apisix = {
                        ssl = {
                            key_encrypt_salt = {"1234567890abcdef"}
                        },
                        data_encryption = {
                            enable = true,
                            keyring = {"umse0chsxjqpjgdxp6xyvflyixqnkqwb"}
                        }
                    }
                }
            }
        }

        local core = require("apisix.core")
        ngx.say(core.json.encode(resp_payload))
    end

    server.api_dataplane_developer_query = function()
        local headers = ngx.req.get_headers()
        for k, v in pairs(headers) do
            ngx.log(ngx.INFO, "consumer_query api receive header [", k, ": ", v,"]")
        end

        local plugin_name = ngx.var.arg_plugin_name
        local key_value = ngx.var.arg_key_value
        local service_id = ngx.var.arg_service_id

        ngx.log(ngx.INFO, "receive data plane developer_query: ", plugin_name, ", ", key_value, ", ", service_id)

        local auth_plugin_payload = {
            ["key-auth"] = {
                ["auth-one"] = {
                    credential_id = "05ade19c-44ac-4d87-993c-c877dbce5d34",
                    consumer_name = "developer_test",
                    username = "developer_test",
                    labels = {
                        application_id = "1e0388e9-05cf-4f96-965c-3bdff2c81769",
                        api_product_id = "5c7d2ccf-08e3-43b9-956f-6e0f58de6142",
                        developer_id = "1a758cf0-4166-48bf-9349-b0b06c4e590b",
                        subscription_id = "6e8954e6-c95e-40cc-b778-688efd65a90b",
                        developer_username = "developer_test",
                    },
                    plugins = {
                        ["consumer-restriction"] = {
                            type = "route_id",
                            whitelist = {"1"},
                            ["rejected_code"] = 403
                        },
                    },
                    auth_conf = {
                        key = "ppXvv68X3XHOqe/D/cB5Xg=="
                    },
                    modifiedIndex = 111
                }
            }
        }

        local payload = auth_plugin_payload[plugin_name] and auth_plugin_payload[plugin_name][key_value]
        if not payload then
            return ngx.exit(404)
        end

        local core = require("apisix.core")
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

=== TEST 1: enable key-auth plugin
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
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
                        "portal-auth":{
                            "auth_plugins": [
                                {
                                    "key-auth": {}
                                }
                            ]
                        }
                    },
                    "uri": "/hello"
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



=== TEST 2: invalid apikey
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- request
GET /hello
--- more_headers
apikey: invalid
--- error_code: 401
--- response_body
{"message":"Authorization Failed"}
--- error_log
Invalid API key in request
not found consumer, status: 404



=== TEST 3: access success
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- request
GET /hello
--- more_headers
apikey: auth-one
--- error_code: 200
--- response_body
hello world
--- error_log
receive data plane developer_query: key-auth, auth-one



=== TEST 4: enable key-auth plugin specify header and query
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
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
                        "portal-auth":{
                            "auth_plugins": [
                                {
                                    "key-auth": {
                                        "header": "authkey",
                                        "query": "authkey"
                                    }
                                }
                            ]
                        }
                    },
                    "uris": ["/hello", "/log_request"]
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



=== TEST 5: specify invalid header
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- request
GET /hello
--- more_headers
apikey: auth-one
--- error_code: 401
--- response_body
{"message":"Authorization Failed"}
--- error_log
Missing API key found in request



=== TEST 6: specify invalid query
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- request
GET /hello?apikey=auth-one
--- error_code: 401
--- response_body
{"message":"Authorization Failed"}
--- error_log
Missing API key found in request



=== TEST 7: access success with header authkey
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- request
GET /hello
--- more_headers
authkey: auth-one
--- error_code: 200
--- response_body
hello world
--- error_log
receive data plane developer_query: key-auth, auth-one



=== TEST 8: access success with query authkey
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- request
GET /hello?authkey=auth-one
--- error_code: 200
--- response_body
hello world
--- error_log
receive data plane developer_query: key-auth, auth-one



=== TEST 9: add route 2
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/2',
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
                        "portal-auth":{
                            "auth_plugins": [
                                {
                                    "key-auth": {
                                        "header": "authkey",
                                        "query": "authkey"
                                    }
                                }
                            ]
                        }
                    },
                    "uri": "/hello_chunked"
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



=== TEST 10: route 2 is forbidden
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- request
GET /hello_chunked
--- more_headers
authkey: auth-one
--- error_code: 403
--- response_body
{"message":"The route_id is forbidden."}
--- error_log
cache_key: key-auth/auth-one
receive data plane developer_query: key-auth, auth-one



=== TEST 11: access success with header authkey
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- request
GET /hello
--- more_headers
authkey: auth-one
--- error_code: 200
--- response_body
hello world
--- error_log
cache_key: key-auth/auth-one
receive data plane developer_query: key-auth, auth-one



=== TEST 12: set service 1
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/services/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "portal-auth":{
                            "api_product_id": "5c7d2ccf-08e3-43b9-956f-6e0f58de6142",
                            "auth_plugins": [
                                {
                                    "key-auth": {
                                        "header": "authkey",
                                        "query": "authkey"
                                    }
                                }
                            ]
                        },
                        "prometheus": {}
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
--- request
GET /t
--- response_body
passed



=== TEST 13: route refer to service 1
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
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
                    "service_id": "1",
                    "uri": "/log_request"
                }]]
                )

            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            local code, body = t('/apisix/admin/routes/metrics',
                 ngx.HTTP_PUT,
                 [[{
                    "plugins": {
                        "public-api": {}
                    },
                    "uri": "/apisix/prometheus/metrics"
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



=== TEST 14: control plane receive service_id
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- request
GET /log_request
--- more_headers
authkey: auth-one
--- error_code: 200
--- error_log
cache_key: key-auth/auth-one/1
receive data plane developer_query: key-auth, auth-one, 1



=== TEST 15: access upstream with more headers x-api7-portal-*
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- request
GET /log_request
--- more_headers
authkey: auth-one
--- error_code: 200
--- error_log
x-api7-portal-api-product-id: 5c7d2ccf-08e3-43b9-956f-6e0f58de6142
x-api7-portal-application-id: 1e0388e9-05cf-4f96-965c-3bdff2c81769
x-api7-portal-credential-id: 05ade19c-44ac-4d87-993c-c877dbce5d34
x-api7-portal-developer-id: 1a758cf0-4166-48bf-9349-b0b06c4e590b
x-api7-portal-developer-username: developer_test
x-api7-portal-subscription-id: 6e8954e6-c95e-40cc-b778-688efd65a90b



=== TEST 16: access upstream with request_id header
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- request
GET /log_request
--- more_headers
authkey: auth-one
--- error_code: 200
--- error_log eval
qr/x-api7-portal-request-id: [0-9a-f-]+,/



=== TEST 17: api_product_id label present in prometheus metrics
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- pipelined_requests eval
["GET /log_request", "GET /log_request", "GET /apisix/prometheus/metrics"]
--- error_code eval
[401, 401, 200]
--- response_body_like eval
[".*Authorization Failed.*", ".*Authorization Failed.*", ".*apisix_http_status\{code=\"401\",route=\"1\",route_id=\"1\",matched_uri=\"\/log_request\",matched_host=\"\",service=\"1\",service_id=\"1\",consumer=\"\",.*api_product_id=\"5c7d2ccf-08e3-43b9-956f-6e0f58de6142\"\} 2.*"]



=== TEST 18: api_product_id and consumer labels present in prometheus metrics
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- pipelined_requests eval
["GET /log_request", "GET /log_request", "GET /apisix/prometheus/metrics"]
--- more_headers
authkey: auth-one
--- error_code eval
[200, 200, 200]
--- response_body_like eval
[".*", ".*", ".*apisix_http_status\{code=\"200\",route=\"1\",route_id=\"1\",matched_uri=\"\/log_request\",matched_host=\"\",service=\"1\",service_id=\"1\",consumer=\"developer_test\",.*api_product_id=\"5c7d2ccf-08e3-43b9-956f-6e0f58de6142\"\} 2.*"]
