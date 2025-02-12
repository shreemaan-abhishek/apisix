BEGIN {
    $ENV{API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG} = "true";
}
use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_root_location();
no_shuffle();
log_level("info");
workers(2);

add_block_preprocessor(sub {
    my ($block) = @_;

    my $extra_init_by_lua_start = <<_EOC_;
require "agent.hook";
_EOC_

    if (!defined $block->extra_init_by_lua_start) {
        $block->set_value("extra_init_by_lua_start", $extra_init_by_lua_start);
    }

    my $extra_init_by_lua = <<_EOC_;
    local server = require("lib.server")
    server.api_dataplane_heartbeat = function()
        ngx.say("{}")
    end

    server.api_dataplane_streaming_metrics = function()
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

    my $extra_yaml_config = $block->extra_yaml_config // <<_EOC_;
plugin_attr:
  prometheus:
    export_addr:
      port: 1980
_EOC_

    $block->set_value("extra_yaml_config", $extra_yaml_config);

    if ((!defined $block->error_log) && (!defined $block->no_error_log)) {
        $block->set_value("no_error_log", "[error]\n[alert]");
    }
});

run_tests;

__DATA__

=== TEST 1: destroy should be called on removing the custom plugin
--- extra_yaml_config
nginx_config:
  worker_processes: 4
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local core = require("apisix.core")
            assert(core.etcd.set("/plugins", {{name = "test3", is_custom = true}}))

            ngx.sleep(1)

            local key = "/custom_plugins/test3"
local val = {
    name = "test3",
    content = [[
local core = require("apisix.core")

local schema = {
    type = "object",
    properties = {
        body = {
            description = "body to replace upstream response.",
            type = "string"
        },
    },
}

local plugin_name = "test"

local _M = {
    version = 0.2,
    priority = 412,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end
    return true
end

function _M.destroy()
    if not ngx.worker.exiting() then
        core.log.warn("destroy called successfully")
    end
end

return _M
]]
}

            local _, err = core.etcd.set(key, val)
            if err then
                ngx.say(err)
                return
            end
            ngx.sleep(1)
            assert(core.etcd.delete("/plugins")) 
            if err then
                ngx.say(err)
                return
            end
            ngx.say("success")
        }
    }
--- request
GET /t
--- response_body
success
--- error_log
could not find custom plugin [test3], it might be due to the order of etcd events, will retry loading when custom plugin available
destroy called successfully
