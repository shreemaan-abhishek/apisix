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

    my $http_config = $block->http_config // <<_EOC_;
lua_shared_dict config 5m;
_EOC_

    $block->set_value("http_config", $http_config);

    my $extra_init_by_lua = <<_EOC_;
    local server = require("lib.server")
    server.api_dataplane_heartbeat = function()
        ngx.sleep(30) -- 12s timeout, 10s interval
        ngx.say("{}")
    end

    server.api_dataplane_metrics = function()
        ngx.sleep(30) -- 12s timeout, 1s interval
    end

    server.apisix_prometheus_metrics = function()
        ngx.say('apisix_http_status{code="200",route="httpbin",matched_uri="/*",matched_host="nic.httpbin.org",service="",consumer="",node="172.30.5.135"} 61')
    end
_EOC_

    $block->set_value("extra_init_by_lua", $extra_init_by_lua);
});

run_tests;

__DATA__

=== TEST 1: heartbeat and telemetry requests will send one by one when http request timeout
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- yaml_config
plugin_attr:
  prometheus:
    export_addr:
      port: 1980
api7ee:
  telemetry:
    interval: 1
  http_timeout: 12s
--- config
    location /t {
        content_by_lua_block {
            ngx.say("ok")
        }
    }
--- request
GET /t
--- wait: 30
--- error_log
heartbeat failed timeout
upload metrics failed timeout
previous heartbeat request not finished yet
previous metrics upload request not finished yet
