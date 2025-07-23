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
        local portal_api_calls = payload.portal_api_calls

        if portal_api_calls then
            for _, item in ipairs(portal_api_calls) do
                ngx.log(ngx.INFO, "developer_id: ", item.developer_id)
                ngx.log(ngx.INFO, "api_product_id: ", item.api_product_id)
                ngx.log(ngx.INFO, "application_id: ", item.application_id)
                ngx.log(ngx.INFO, "credential_id: ", item.credential_id)
                ngx.log(ngx.INFO, "subscription_id: ", item.subscription_id)
                ngx.log(ngx.INFO, item.status_code, ":", item.count)
            end
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
  heartbeat_interval: 2
_EOC_

    $block->set_value("extra_yaml_config", $extra_yaml_config);

    if ((!defined $block->error_log) && (!defined $block->no_error_log)) {
        $block->set_value("no_error_log", "[error]");
    }
});

run_tests;

__DATA__

=== TEST 1: create a route with portal-auth
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
                                    "basic-auth": {}
                                }
                            ]
                        },
                        "serverless-post-function": {
                            "phase": "rewrite",
                            "functions": ["
                                return function(conf, ctx)
                                    local core = require(\"apisix.core\")
                                    local uri = ctx.var.uri
                                    local status = tonumber(string.sub(uri, -3))
                                    return core.response.exit(status)
                                end
                            "]
                        }
                    },
                    "uri": "/status/*"
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



=== TEST 2: request routes with basic-auth
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- timeout: 30
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.http"
            local httpc = http.new()
            for _, code in ipairs({200, 200, 200, 200, 401, 401, 401, 500, 500, 503}) do
                local resp = httpc:request_uri("http://127.0.0.1:" .. ngx.var.server_port .. "/status/" .. tostring(code), { headers = { ["Authorization"] = "Basic cm9zZToxMjM0NTY=" } })
                if resp.status ~= code then
                    ngx.status = 400
                    ngx.say("failed to request /status/" .. tostring(code))
                    return
                end
            end
            ngx.sleep(11)
            ngx.status = 200
            ngx.say("passed")
        }
    }
--- error_log
developer_id: 1a758cf0-4166-48bf-9349-b0b06c4e590b
api_product_id: 5c7d2ccf-08e3-43b9-956f-6e0f58de6142
application_id: 1e0388e9-05cf-4f96-965c-3bdff2c81769
credential_id: 05ade19c-44ac-4d87-993c-c877dbce5d34
subscription_id: 6e8954e6-c95e-40cc-b778-688efd65a90b
200:4
401:3
500:2
503:1
