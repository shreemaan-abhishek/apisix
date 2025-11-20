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
    server.api_dataplane_heartbeat = function()
        ngx.req.read_body()
        local data = ngx.req.get_body_data()

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

        ngx.say("{}")
    end

    server.api_dataplane_developer_query = function()
        local plugin_name = ngx.var.arg_plugin_name
        local key_value = ngx.var.arg_key_value
        local service_id = ngx.var.arg_service_id

        ngx.log(ngx.INFO, "receive data plane developer_query: ", plugin_name, ", ", key_value, ", ", service_id)
        local payload
        if plugin_name == "basic-auth" and key_value == "rose" then
            payload = {
                credential_id = "05ade19c-44ac-4d87-993c-c877dbce5d34",
                consumer_name = "rose",
                username = "rose",
                labels = {
                    application_id = "1e0388e9-05cf-4f96-965c-3bdff2c81769",
                    developer_id = "1a758cf0-4166-48bf-9349-b0b06c4e590b",
                    developer_username = "rose",
                    -- with subscription
                    subscription_id = "6e8954e6-c95e-40cc-b778-688efd65a90b",
                    api_product_id = "5c7d2ccf-08e3-43b9-956f-6e0f58de6142",
                },
                auth_conf = {
                    username = "rose",
                    password = "123456"
                },
                modifiedIndex = 111
            }
        elseif plugin_name == "key-auth" and key_value == "jack" then
            payload = {
                credential_id = "05ade19c-44ac-4d87-993c-c877dbce5d34",
                consumer_name = "jack",
                username = "jack",
                labels = {
                    application_id = "1e0388e9-05cf-4f96-965c-3bdff2c81769",
                    developer_id = "1a758cf0-4166-48bf-9349-b0b06c4e590b",
                    developer_username = "developer_test",
                    -- without subscription
                },
                plugins = {
                    ["fault-injection"] = {
                        abort = {
                            http_status = 403,
                            body = "No any subscription yet",
                        },
                    },
                },
                modifiedIndex = 111
            }
        else
            ngx.exit(404)
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
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    },
                    "plugins":{
                        "portal-auth":{
                            "auth_plugins": [
                                {
                                    "basic-auth": {}
                                },
                                {
                                    "key-auth": {}
                                }
                            ]
                        }
                    },
                    "uri": "/specific_status"
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



=== TEST 2: request routes with basic-auth and key-auth
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.http"
            local httpc = http.new()

            -- developer that using basic-auth has subscription
            for _, code in ipairs({200, 200, 200, 200, 401, 401, 401, 500, 500, 503}) do
                local resp = httpc:request_uri("http://127.0.0.1:" .. ngx.var.server_port .. "/specific_status",
                        { headers = { ["Authorization"] = "Basic cm9zZToxMjM0NTY=", ["x-test-upstream-status"] = code } })
                if resp.status ~= code then
                    ngx.status = 400
                    ngx.say("failed to request /status/" .. tostring(code))
                    return
                end
            end

            -- developer that using key-auth don't has subscription
            for i = 1, 5 do
                local resp = httpc:request_uri("http://127.0.0.1:" .. ngx.var.server_port .. "/specific_status",
                        { headers = { ["apikey"] = "jack" }, ["x-test-upstream-status"] = 200 })
                if resp.status ~= 403 then
                    ngx.say("expect 403, got " .. tostring(resp.status))
                    return
                end
                if resp.body ~= "No any subscription yet" then
                    ngx.say("got a unexpect body: " .. tostring(resp.body))
                    return
                end
            end

            ngx.sleep(3)
            ngx.status = 200
            ngx.say("passed")
        }
    }
--- response_body
passed
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
--- no_error_log
[error]
