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
        ngx.req.read_body()
        local data = ngx.req.get_body_data()
        ngx.log(ngx.NOTICE, "receive data plane heartbeat: ", data)

        local json_decode = require("toolkit.json").decode
        local payload = json_decode(data)

        if not payload.gateway_group_id then
            ngx.log(ngx.ERR, "missing gateway_group_id")
            return ngx.exit(400)
        end
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
        if not payload.conf_server_revision then
            ngx.log(ngx.ERR, "missing conf_server_revision")
            return ngx.exit(400)
        end
        if not payload.ports then
            ngx.log(ngx.ERR, "missing ports")
            return ngx.exit(400)
        end

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

    server.api_dataplane_metrics = function()
        ngx.req.read_body()
        local data = ngx.req.get_body_data()
        ngx.log(ngx.NOTICE, "receive data plane metrics: ", data)

        local json_decode = require("toolkit.json").decode
        local payload = json_decode(data)

        if not payload.gateway_group_id then
            ngx.log(ngx.ERR, "missing gateway_group_id")
            return ngx.exit(400)
        end
        if not payload.instance_id then
            ngx.log(ngx.ERR, "missing instance_id")
            return ngx.exit(400)
        end
        if not payload.metrics then
            ngx.log(ngx.ERR, "missing metrics")
            return ngx.exit(400)
        end
        ngx.log(ngx.NOTICE, "metrics size: ", #payload.metrics)
    end

    server.apisix_prometheus_metrics = function()
        ngx.say('apisix_http_status{code="200",route="httpbin",matched_uri="/*",matched_host="nic.httpbin.org",service="",consumer="",node="172.30.5.135"} 61')
    end
_EOC_

    $block->set_value("extra_init_by_lua", $extra_init_by_lua);

    if (!$block->request) {
        $block->set_value("request", "GET /t");
    }

    if ((!defined $block->error_log) && (!defined $block->no_error_log)) {
        $block->set_value("no_error_log", "[error]");
    }
});

run_tests;

__DATA__

=== TEST 1: heartbeat failed
--- main_config
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1234;
--- config
    location /t {
        content_by_lua_block {
            ngx.say("ok")
        }
    }
--- wait: 12
--- error_log
heartbeat failed



=== TEST 2: heartbeat success with gateway group id env
--- main_config
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- config
    location /t {
        content_by_lua_block {
            ngx.say("ok")
        }
    }
--- wait: 12
--- error_log
receive data plane heartbeat
heartbeat successfully
gateway_group 'default'



=== TEST 3: heartbeat success with gateway group id env
--- main_config
env API7_CONTROL_PLANE_GATEWAY_GROUP_ID=a8db303a-8019-427a-bd01-9946d097e471;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- config
    location /t {
        content_by_lua_block {
            ngx.say("ok")
        }
    }
--- wait: 12
--- error_log
receive data plane heartbeat
heartbeat successfully
gateway_group 'a8db303a-8019-427a-bd01-9946d097e471'



=== TEST 5: upload metrics success
--- main_config
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
            ngx.say("ok")
        }
    }
--- wait: 17
--- error_log
receive data plane metrics
metrics size: 141
upload metrics to control plane successfully
gateway_group 'default'



=== TEST 6: upload metrics success
--- main_config
env API7_CONTROL_PLANE_GATEWAY_GROUP_ID=a8db303a-8019-427a-bd01-9946d097e471;
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
            ngx.say("ok")
        }
    }
--- wait: 17
--- error_log
receive data plane metrics
metrics size: 141
upload metrics to control plane successfully
gateway_group 'a8db303a-8019-427a-bd01-9946d097e471'



=== TEST 7: upload truncated metrics success
--- main_config
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_MAX_METRICS_SIZE_DEBUG=8;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
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
--- wait: 17
--- error_log
metrics size is too large, truncating it
receive data plane metrics
metrics size: 8
upload metrics to control plane successfully



=== TEST 8: fetch prometheus metrics failed
--- main_config
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- yaml_config
plugin_attr:
  prometheus:
    export_addr:
      port: 1234
--- config
    location /t {
        content_by_lua_block {
            ngx.say("ok")
        }
    }
--- wait: 17
--- error_log
fetch prometheus metrics error



=== TEST 9: get new config
--- main_config
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_MAX_METRICS_SIZE_DEBUG=8;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
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
--- wait: 17
--- error_log
config version changed, old version: 0, new version: 1
