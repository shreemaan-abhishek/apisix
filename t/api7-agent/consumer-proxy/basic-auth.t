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

    server.api_dataplane_streaming_metrics = function()
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
            ["basic-auth"] = {
                jack = {
                    labels = {},
                    credential_id = "b6b00cd8-502a-4696-a01c-1db4a5f73185",
                    auth_conf = {
                        password = "1q1KP2rLD7c/1hmiCSXr/w==",
                        username = "jack"
                    },
                    plugins = {},
                    username = "test",
                    consumer_name = "test"
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

=== TEST 1: enable basic-auth plugin
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
                        "basic-auth": {}
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



=== TEST 2: passwrod is wrong
--- request
GET /hello
--- more_headers
Authorization: Basic amFjazoxMjM=
--- error_code: 401
--- response_body eval
qr/Invalid user authorization/
--- no_error_log
not found consumer, status: 404



=== TEST 3: username not found
--- request
GET /hello
--- more_headers
Authorization: Basic eW9objoxMjM=
--- error_code: 401
--- response_body eval
qr/Invalid user authorization/
--- error_log
not found consumer, status: 404



=== TEST 4: access success
--- request
GET /hello
--- more_headers
Authorization: Basic amFjazpqYWNrLXB3ZA==
--- error_code: 200
--- response_body
hello world
--- error_log
receive data plane consumer_query: basic-auth, jack
consumer_query api receive header [control-plane-token: a7ee-token]



=== TEST 5: enable basic-auth plugin with anonymous consumer
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
                        "basic-auth": {
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



=== TEST 6: invalid Authorization header will lead to fallback to anonymous consumer logic
# in the mock DPM server, an anonymous consumer is configured with limit-count plugin
# in this test we verify the execution of limit-count plugin
--- pipelined_requests eval
["GET /hello", "GET /hello"]
--- more_headers eval
["Authorization: Basic invalid==", "Authorization: Basic invalid=="]
--- error_code eval
[200, 503]



=== TEST 7: same test as above but don't pass Authorization header at all
--- pipelined_requests eval
["GET /hello", "GET /hello"]
--- error_code eval
[200, 503]



=== TEST 8: enable basic-auth plugin with non-existent anonymous consumer
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
                        "basic-auth": {
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



=== TEST 9: anonymous-consumer configured in the route should not be found
--- request
GET /hello
--- error_code: 401
--- error_log
failed to get anonymous consumer not-found-anonymous
--- response_body
{"message":"Invalid user authorization"}
