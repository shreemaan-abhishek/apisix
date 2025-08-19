use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_root_location();

my $pattern = '([^\n]*)$';

add_block_preprocessor(sub {
    my ($block) = @_;
    my $extra_init_by_lua_start = <<_EOC_;
require "agent.hook";
_EOC_

    $block->set_value("extra_init_by_lua_start", $extra_init_by_lua_start);

    my $extra_init_by_lua = <<_EOC_;
    local prometheus = require("prometheus")
    prometheus.metric_data = function()
        return {
            '# HELP apisix_bandwidth Total bandwidth in bytes consumed per service in Apisix',
            '# TYPE apisix_bandwidth counter',
            'apisix_bandwidth{type="egress",route="",service="",consumer="",node=""} 8417',
            'apisix_bandwidth{type="egress",route="1",service="",consumer="",node="127.0.0.1"} 1420',
            '# HELP apisix_etcd_modify_indexes Etcd modify index for APISIX keys',
            '# TYPE apisix_etcd_modify_indexes gauge',
            'apisix_etcd_modify_indexes{key="consumers"} 0',
            'apisix_etcd_modify_indexes{key="global_rules"} 0',
            'apisix_etcd_modify_indexes{key="last_line_metric"} 222',
        }
    end

    local server = require("lib.server")
    server.api_dataplane_streaming_metrics = function()
        local req = require("apisix.core.request")
        local data = req.get_body()

        ngx.log(ngx.NOTICE, "last metric: ", data)
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

=== TEST 1: check if last metric is not missing
--- yaml_config
plugin_attr:
  prometheus:
    export_addr:
      port: 1980
api7ee:
  telemetry:
    interval: 1
--- config
    location /t {
        content_by_lua_block {
            ngx.say("ok")
        }
    }
--- wait: 2
--- error_log
apisix_etcd_modify_indexes{key="last_line_metric"} 222
