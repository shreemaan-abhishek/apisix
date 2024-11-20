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

    server.api_dataplane_metrics = function()
    end

    server.apisix_prometheus_metrics = function()
        ngx.say('apisix_http_status{code="200",route="httpbin",matched_uri="/*",matched_host="nic.httpbin.org",service="",consumer="",node="172.30.5.135"} 61')
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

=== TEST 1: create custom plugin test
--- extra_init_by_lua_start
--- extra_yaml_config
apisix:
  lua_module_hook: ""
--- config
location /t {
    content_by_lua_block {
        local core = require("apisix.core")

        local file, err = io.open("t/api7-agent/testdata/test_metadata.lua", "rb")
        if not file then
            ngx.say(err)
            return
        end

        local data, err = file:read("*all")
        file:close()
        if not data then
            ngx.say(err)
            return
        end
        local key = "/custom_plugins/test-metadata"
        local val = {
            name = "test-metadata",
            content = ngx.encode_base64(data)
        }
        local _, err = core.etcd.set(key, val)
        if err then
            ngx.say(err)
            return
        end
        assert(core.etcd.set("/plugin_metadata/test-metadata", {body = "testingdata"}))
        ngx.say("done")
    }
}
--- request
GET /t
--- response_body
done



=== TEST 2: check error log
--- config
location /t {
    content_by_lua_block {
        ngx.say("done")
    }
}
--- request
GET /t
--- response_body
done
--- no_error_log
failed to get schema for plugin
