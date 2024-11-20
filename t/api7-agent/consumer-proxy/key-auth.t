use t::APISIX 'no_plan';

repeat_each(1);
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

    server.api_dataplane_metrics = function()
        ngx.req.read_body()
        local data = ngx.req.get_body_data()
        ngx.log(ngx.NOTICE, "receive data plane metrics: ", data)

        local json_decode = require("toolkit.json").decode
        local payload = json_decode(data)

        if not payload.instance_id then
            ngx.log(ngx.ERR, "missing instance_id")
            return ngx.exit(400)
        end
        if not payload.metrics then
            ngx.log(ngx.ERR, "missing metrics")
            return ngx.exit(400)
        end
        ngx.log(ngx.NOTICE, "metrics size: ", #payload.metrics)
    end

    server.api_dataplane_consumer_query = function()
        local headers = ngx.req.get_headers()
        for k, v in pairs(headers) do
            ngx.log(ngx.INFO, "consumer_query api receive header [", k, ": ", v,"]")
        end
        local username = ngx.var.arg_username
        if username then
            local consumers = {
                anonymous = {
                    created_at = 1728958679,
                    gateway_group_id = "default",
                    plugins = {
                        ["limit-count"] = {
                            _meta = {
                                disable = false
                            },
                            allow_degradation = false,
                            count = 1,
                            key = "remote_addr",
                            key_type = "var",
                            policy = "local",
                            rejected_code = 503,
                            show_limit_quota_header = true,
                            time_window = 60
                        }
                    },
                    updated_at = 1728958717,
                    username = "anonymous"
                }
            }

            local payload = consumers[username]
            if not payload then
                return ngx.exit(404)
            end

            local core = require("apisix.core")
            ngx.say(core.json.encode(payload))
            return
        end

        local plugin_name = ngx.var.arg_plugin_name
        local key_value = ngx.var.arg_key_value

        ngx.log(ngx.INFO, "receive data plane consumer_query: ", plugin_name, ", ", key_value)

        local auth_plugin_payload = {
            ["key-auth"] = {
                ["auth-one"] = {
                    credential_id = "05ade19c-44ac-4d87-993c-c877dbce5d34",
                    consumer_name = "test",
                    labels = {},
                    username = "test",
                    plugins = {},
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

    server.apisix_prometheus_metrics = function()
        ngx.say('apisix_http_status{code="200",route="httpbin",matched_uri="/*",matched_host="nic.httpbin.org",service="",consumer="",node="172.30.5.135"} 61')
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
  consumer_proxy:
    enable: true
    cache_success_count: 512
    cache_success_ttl: 60
    cache_failure_count: 512
    cache_failure_ttl: 60
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
                        "key-auth": {}
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
--- response_body eval
qr/Invalid API key in request/
--- error_log
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
receive data plane consumer_query: key-auth, auth-one
consumer_query api receive header [control-plane-token: a7ee-token]


=== TEST 4: enable key-auth plugin with anonymous consumer
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
                        "key-auth": {
                            "anonymous_consumer": "anonymous"
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



=== TEST 5: invalid apikey will lead to fallback to anonymous consumer logic
# in the mock DPM server, an anonymous consumer is configured with limit-count plugin
# in this test we verify the execution of limit-count plugin
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- pipelined_requests eval
["GET /hello", "GET /hello"]
--- more_headers eval
["apikey: invalid", "apikey: invalid"]
--- error_code eval
[200, 503]



=== TEST 6: same test as above but pass no apikey
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- pipelined_requests eval
["GET /hello", "GET /hello"]
--- error_code eval
[200, 503]



=== TEST 7: enable key-auth plugin with non-existent anonymous consumer
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
                        "key-auth": {
                            "anonymous_consumer": "not-found-anonymous"
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



=== TEST 8: anonymous-consumer configured in the route should not be found
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- request
GET /hello
--- error_code: 401
--- error_log
failed to get anonymous consumer not-found-anonymous
--- response_body
{"message":"Invalid user authorization"}
