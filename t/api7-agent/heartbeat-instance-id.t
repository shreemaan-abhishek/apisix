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
        if not payload.run_id then
            ngx.log(ngx.ERR, "missing run_id")
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
            },
            instance_id = "a7ee-instance-id-1",
        }

        local core = require("apisix.core")
        ngx.say(core.json.encode(resp_payload))
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

=== TEST 1: instance_id rotation
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            ngx.sleep(1)

            ngx.say("uid: ", core.id.get())
            local log_file = ngx.config.prefix() .. "conf/apisix.uid"
            local f = io.open(log_file, "r")
            local uid = f:read("*a")
            ngx.say("apisix.uid: ", uid)

            -- etcd request with new instance_id
            local etcd = require("apisix.core.etcd")
            assert(etcd.set("/plugin_configs/1",
                {id = 1, plugins = { ["uri-blocker"] = { block_rules =  {"root.exe","root.m+"} }}}
            ))
            -- wait for sync
            ngx.sleep(0.6)
        }
    }
--- request
GET /t
--- response_body
uid: a7ee-instance-id-1
apisix.uid: a7ee-instance-id-1
--- error_log
new uid: a7ee-instance-id-1
"Gateway-Instance-ID":"a7ee-instance-id-1"
