use t::APISIX 'no_plan';

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

        local resp_payload = {
            config = {
                config_version = 1,
                config_payload = {
                    apisix = {
                        ssl = {
                            key_encrypt_salt = {"1234567890abcdef"},
                        }
                    }
                },
                gateway_group_id = "some-id",
            }
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

    if ((!defined $block->error_log) && (!defined $block->no_error_log)) {
        $block->set_value("no_error_log", "[error]");
    }
});

run_tests;

__DATA__

=== TEST 1: setup public API route and test route
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- config
    location /t {
        content_by_lua_block {
            local data = {
                url = "/apisix/admin/routes/metrics",
                data = [[{
                    "plugins": {
                        "public-api": {}
                    },
                    "uri": "/apisix/prometheus/metrics"
                }]]
            }

            local t = require("lib.test_admin").test

            local code, body = t(data.url, ngx.HTTP_PUT, data.data)
            ngx.say(code..body)
        }
    }
--- response_body
201passed
--- error_log
fetch prometheus metrics error connection refused



=== TEST 2: fetch the prometheus metric data
--- yaml_config
plugin_attr:
  prometheus:
    export_addr:
      port: 1984
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body, actual_body = t("/apisix/prometheus/metrics", ngx.HTTP_GET)
            ngx.say(actual_body)
        }
    }
--- request
GET /t
--- response_body eval
qr/apisix_etcd_modify_indexes\{key="consumers",gateway_group_id="some-id",instance_id="[\w\d-]+"\} \d+/



=== TEST 3: fetch the prometheus metric data
--- yaml_config
plugin_attr:
  prometheus:
    export_addr:
      port: 1984
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body, actual_body = t("/apisix/prometheus/metrics", ngx.HTTP_GET)
            ngx.say(actual_body)
        }
    }
--- request
GET /t
--- response_body eval
qr/apisix_etcd_reachable\{gateway_group_id="some-id",instance_id="[\w\d-]+"\} \d+/



=== TEST 4: fetch the prometheus metric data
--- yaml_config
plugin_attr:
  prometheus:
    export_addr:
      port: 1984
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body, actual_body = t("/apisix/prometheus/metrics", ngx.HTTP_GET)
            ngx.say(actual_body)
        }
    }
--- request
GET /t
--- response_body eval
qr/apisix_etcd_modify_indexes\{key="x_etcd_index",gateway_group_id="some-id",instance_id="[\w\d-]+"\} \d+/



=== TEST 5: fetch the prometheus metric data
--- yaml_config
plugin_attr:
  prometheus:
    export_addr:
      port: 1984
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body, actual_body = t("/apisix/prometheus/metrics", ngx.HTTP_GET)
            ngx.say(actual_body)
        }
    }
--- request
GET /t
--- response_body eval
qr/apisix_http_requests_total\{gateway_group_id="some-id",instance_id="[\w\d-]+"\} \d+/



=== TEST 6: fetch the prometheus metric data
--- yaml_config
plugin_attr:
  prometheus:
    export_addr:
      port: 1984
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body, actual_body = t("/apisix/prometheus/metrics", ngx.HTTP_GET)
            ngx.say(actual_body)
        }
    }
--- request
GET /t
--- response_body eval
qr/apisix_nginx_http_current_connections\{state="writing",gateway_group_id="some-id",instance_id="[\w\d-]+"\} \d+/



=== TEST 7: fetch the prometheus metric data
--- yaml_config
plugin_attr:
  prometheus:
    export_addr:
      port: 1984
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body, actual_body = t("/apisix/prometheus/metrics", ngx.HTTP_GET)
            ngx.say(actual_body)
        }
    }
--- request
GET /t
--- response_body eval
qr/apisix_node_info\{hostname=".*",gateway_group_id="some-id",instance_id="[\w\d-]+"\} \d+/



=== TEST 8: fetch the prometheus metric data
--- yaml_config
plugin_attr:
  prometheus:
    export_addr:
      port: 1984
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body, actual_body = t("/apisix/prometheus/metrics", ngx.HTTP_GET)
            ngx.say(actual_body)
        }
    }
--- request
GET /t
--- response_body eval
qr/apisix_shared_dict_capacity_bytes\{name="access-tokens",gateway_group_id="some-id",instance_id="[\w\d-]+"\} \d+/



=== TEST 9: fetch the prometheus metric data
--- yaml_config
plugin_attr:
  prometheus:
    export_addr:
      port: 1984
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body, actual_body = t("/apisix/prometheus/metrics", ngx.HTTP_GET)
            ngx.say(actual_body)
        }
    }
--- request
GET /t
--- response_body eval
qr/apisix_shared_dict_free_space_bytes\{name="access-tokens",gateway_group_id="some-id",instance_id="[\w\d-]+"\} \d+/
