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
        if plugin_name ~= "basic-auth" or key_value ~= "rose" then
            return ngx.exit(404)
        end

        local core = require("apisix.core")
        local payload = {
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
                username = "rose",
                password = "123456"
            },
            modifiedIndex = 111
        }
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
                        "portal-auth":{
                            "auth_plugins": [
                                {
                                    "basic-auth": {}
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



=== TEST 2: invalid username
--- request
GET /hello
--- more_headers
Authorization: Basic amFjazoxMjM0NTY=
--- error_code: 401
--- response_body
{"message":"Authorization Failed"}
--- error_log
not found consumer, status: 404



=== TEST 3: access success
--- request
GET /hello
--- more_headers
Authorization: Basic cm9zZToxMjM0NTY=
--- error_code: 200
--- response_body
hello world
--- error_log
receive data plane developer_query: basic-auth, rose



=== TEST 4: access success with uppercase
--- request
GET /hello
--- more_headers
Authorization: BASIC cm9zZToxMjM0NTY=
--- error_code: 200
--- response_body
hello world
--- error_log
receive data plane developer_query: basic-auth, rose



=== TEST 5: access success with lowercase
--- request
GET /hello
--- more_headers
Authorization: basic cm9zZToxMjM0NTY=
--- error_code: 200
--- response_body
hello world
--- error_log
receive data plane developer_query: basic-auth, rose



=== TEST 6: access success with mixed case
--- request
GET /hello
--- more_headers
Authorization: bASic cm9zZToxMjM0NTY=
--- error_code: 200
--- response_body
hello world
--- error_log
receive data plane developer_query: basic-auth, rose
