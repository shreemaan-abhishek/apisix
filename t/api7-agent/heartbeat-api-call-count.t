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

        if not payload.api_calls then
            ngx.log(ngx.ERR, "missing api_calls")
            return ngx.exit(400)
        end

        ngx.log(ngx.NOTICE,"the payload.api_calls is: ", payload.api_calls)
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
                            "httpbin.org:80": 1
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



=== TEST 2: verify
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- request
GET /headers
--- wait: 11
--- timeout: 11
--- no_error_log
missing api_calls
--- grep_error_log eval
qr/the payload.api_calls is: \d+/
--- grep_error_log_out
the payload.api_calls is: 0
the payload.api_calls is: 1
