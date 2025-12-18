use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_root_location();

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!defined $block->extra_init_by_lua_start) {
        my $extra_init_by_lua_start = <<_EOC_;
require "agent.hook";
_EOC_
        $block->set_value("extra_init_by_lua_start", $extra_init_by_lua_start);
    }

    my $extra_init_by_lua = <<_EOC_;
    local server = require("lib.server")
    server.api_dataplane_heartbeat = function()
        local core = require("apisix.core")
        ngx.req.read_body()
        local data = ngx.req.get_body_data()
        ngx.log(ngx.NOTICE, "receive data plane heartbeat: ", data)

        local json_decode = require("toolkit.json").decode
        local payload = json_decode(data)
        ngx.log(ngx.NOTICE, "num cores: ", payload.cores)
        ngx.log(ngx.NOTICE, "gateway running_mode: ", payload.running_mode)

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
        ngx.say(core.json.encode(resp_payload))
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

=== TEST 1: in non backup running_mode, cores is one and running_mode should be standard
--- yaml_config
plugin_attr:
  prometheus:
    export_addr:
      port: 1980
--- config
    location /t {
        content_by_lua_block {
            ngx.say("ok")
        }
    }
--- wait: 3
--- error_log
num cores: 1
gateway running_mode: standard



=== TEST 2: in backup running_mode, cores is one and running_mode should be backup
--- yaml_config
nginx_config:
  error_log_level: info
deployment:
  fallback_cp:
    interval: 1
    mode: "write"
    aws_s3:
      access_key: "dfvsdfv"
      secret_key: "xdfbsdf"
      region: "us-west-2"
      resource_bucket: "fallback-cp-data"
      config_bucket: "fallback-cp-config"
    azure_blob:
      account_name: fallbackcp
      account_key: "sadgf"
      resource_container: "fallback-cp-data"
      config_container: "fallback-cp-config"
--- config
    location /t {
        content_by_lua_block {
            ngx.say("ok")
        }
    }
--- wait: 3
--- error_log
num cores: 1
gateway running_mode: backup
