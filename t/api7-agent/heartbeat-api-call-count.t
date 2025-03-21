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

        if not payload.api_calls_per_code then
            ngx.log(ngx.ERR, "missing api_calls_per_code")
            return ngx.exit(400)
        end

        if next(payload.api_calls_per_code) == nil then
            ngx.log(ngx.NOTICE, "api_calls_per_code is empty")
        end

        for k,v in pairs(payload.api_calls_per_code) do
            ngx.log(ngx.NOTICE, "the payload.api_calls_per_code[", k, "] is: ", v)
        end

        ngx.log(ngx.NOTICE, "the payload.api_calls is: ", payload.api_calls)

        local resp_payload = {
            config = {
                config_version = 1,
                config_payload = {
                    apisix = {
                        ssl = {
                            key_encrypt_salt = {"1234567890abcdef"},
                        }
                    }
                }
            }
        }

        local core = require("apisix.core")
        ngx.say(core.json.encode(resp_payload))
    end

    server.apisix_collect_nginx_status = function()
        local prometheus = require("apisix.plugins.prometheus.exporter")
        prometheus.collect_api_specific_metrics()
    end

    server.apisix_nginx_status = function()
        ngx.say([[
Active connections: 6
server accepts handled requests
 11 22 23
Reading: 0 Writing: 6 Waiting: 0
]])
    end

_EOC_

    $block->set_value("extra_init_by_lua", $extra_init_by_lua);

    if (!$block->request) {
        if (!$block->stream_request) {
            $block->set_value("request", "GET /t");
        }
    }

    if ((!defined $block->error_log) && (!defined $block->no_error_log)) {
        $block->set_value("no_error_log", "[error]");
    }
});

run_tests;

__DATA__

=== TEST 1: test incremented api call count in hearbeat
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- yaml_config
plugin_attr:
  prometheus:
    export_addr:
      port: 1980
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
                    "desc": "new route",
                    "uri": "/headers"
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



=== TEST 2: send multiple requests to test the api call count
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- yaml_config
plugin_attr:
  prometheus:
    export_addr:
      port: 1980
--- timeout: 15
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.http"
            local httpc = http.new()
            for _, uri in ipairs({"/headers", "/not_exist_route"}) do
                local resp = httpc:request_uri("http://127.0.0.1:" .. ngx.var.server_port .. uri)
                if not resp then
                    ngx.say("failed to request test server")
                    return
                end
            end
            ngx.sleep(11)
            ngx.say("pass")
        }
    }
--- no_error_log
missing api_calls
--- error_log eval
qr/api_calls_per_code is empty/ and
qr/the payload\.api_calls_per_code\[200\] is: 1/ and
qr/the payload\.api_calls_per_code\[404\] is: 1/ and
qr/the payload\.api_calls is: 2/



=== TEST 3: create a route that return any status code
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- yaml_config
plugin_attr:
  prometheus:
    export_addr:
      port: 1980
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t("/apisix/admin/routes/1",
                 ngx.HTTP_PUT,
                 [[{
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    },
                    "uri": "/status/*",
                    "plugins": {
                            "serverless-pre-function": {
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
                        }
                }]]
            )
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 4: send multiple requests to test the api call count
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- yaml_config
plugin_attr:
  prometheus:
    export_addr:
      port: 1980
--- timeout: 30
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.http"
            local httpc = http.new()
            for _, code in ipairs({301, 401, 401, 200, 503, 200, 503, 500}) do
                local resp = httpc:request_uri("http://127.0.0.1:" .. ngx.var.server_port .. "/status/" .. tostring(code))
                if resp.status ~= code then
                    ngx.say("failed to request /status/" .. tostring(code))
                    return
                end
            end
            ngx.sleep(11)
            for _, code in ipairs({301, 401, 401, 200, 503, 200, 503, 500}) do
                local resp = httpc:request_uri("http://127.0.0.1:" .. ngx.var.server_port .. "/status/" .. tostring(code))
                if resp.status ~= code then
                    ngx.say("failed to request /status/" .. tostring(code))
                    return
                end
            end
            ngx.sleep(11)
            ngx.say("pass")
        }
    }
--- no_error_log eval
qr/missing api_calls/ and
qr/the payload\.api_calls_per_code\[200\] is: 4/ and
qr/the payload\.api_calls_per_code\[401\] is: 4/ and
qr/the payload\.api_calls_per_code\[301\] is: 2/ and
qr/the payload\.api_calls_per_code\[500\] is: 2/ and
qr/the payload\.api_calls_per_code\[503\] is: 4/ and
qr/the payload\.api_calls is: 16/
--- error_log eval
qr/the payload\.api_calls_per_code\[200\] is: 2/ and
qr/the payload\.api_calls_per_code\[401\] is: 2/ and
qr/the payload\.api_calls_per_code\[301\] is: 1/ and
qr/the payload\.api_calls_per_code\[500\] is: 1/ and
qr/the payload\.api_calls_per_code\[503\] is: 2/ and
qr/the payload\.api_calls is: 8/
