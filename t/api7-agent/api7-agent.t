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

        if payload.version == "3.1.1" then
            ngx.status = 403
            ngx.say(core.json.encode({
                error = "gateway version not supported",
            }))
            return ngx.exit(403)
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
        ngx.say(core.json.encode(resp_payload))
    end

    server.api_dataplane_streaming_metrics = function()
        local req = require("apisix.core.request")
        local data = req.get_body()
        ngx.log(ngx.NOTICE, "receive data plane metrics: ", #data)

        if not ngx.req.get_headers()["X-Instance-Id"] then
            ngx.log(ngx.ERR, "missing instance_id")
            return ngx.exit(400)
        end
        if ngx.req.get_headers()["Transfer-Encoding"] ~= "chunked" then
            ngx.log(ngx.ERR, "transfer-encoding must be chunked")
            return ngx.exit(400)
        end
        ngx.log(ngx.NOTICE, "metrics size: ", #data)
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

=== TEST 1: heartbeat failed
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
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



=== TEST 2: upload metrics success
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
            ngx.say("ok")
        }
    }
--- wait: 17
--- error_log
receive data plane metrics
metrics size:
upload metrics to control plane successfully



=== TEST 3: set telemetry interval
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
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
registered timer to send telemetry data to control plane
upload metrics to control plane successfully



=== TEST 4: upload truncated metrics success
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- yaml_config
plugin_attr:
  prometheus:
    export_addr:
      port: 1980
api7ee:
  telemetry:
    interval: 1
    max_metrics_size: 117
--- config
    location /t {
        content_by_lua_block {
            ngx.say("ok")
        }
    }
--- wait: 2
--- error_log
registered timer to send telemetry data to control plane
metrics size is too large, truncated it
receive data plane metrics
metrics size: 237
upload metrics to control plane successfully



=== TEST 5: disable telemetry
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- yaml_config
plugin_attr:
  prometheus:
    export_addr:
      port: 1980
api7ee:
  telemetry:
    enable: false
--- config
    location /t {
        content_by_lua_block {
            ngx.say("ok")
        }
    }
--- error_log
disabled send telemetry data to control plane



=== TEST 6: fetch nginx API related metrics failed
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- yaml_config
plugin_attr:
  prometheus:
    export_addr:
      port: 1234
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
fetch nginx metrics error connection refused



=== TEST 7: get new config
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
            ngx.say("ok")
        }
    }
--- error_log
config version changed, old version: 0, new version: 1



=== TEST 8: create stream_proxy
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- yaml_config
apisix:
  stream_proxy:
    tcp:
    - addr: 9100
plugin_attr:
  prometheus:
    export_addr:
      port: 1980
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local etcd = require("apisix.core.etcd")
            local code, body = t('/apisix/admin/stream_routes/1',
                ngx.HTTP_PUT,
                [[{
                    "remote_addr": "127.0.0.1",
                    "desc": "test-desc",
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    },
                    "desc": "new route"
                }]],
                [[{
                    "value": {
                        "remote_addr": "127.0.0.1",
                        "desc": "test-desc",
                        "upstream": {
                            "nodes": {
                                "127.0.0.1:1980": 1
                            },
                            "type": "roundrobin"
                        },
                        "desc": "new route"
                    },
                    "key": "/apisix/stream_routes/1"
                }]]
                )

            ngx.status = code
            ngx.say(body)

            local res = assert(etcd.get('/stream_routes/1'))
            local create_time = res.body.node.value.create_time
            assert(create_time ~= nil, "create_time is nil")
            local update_time = res.body.node.value.update_time
            assert(update_time ~= nil, "update_time is nil")
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 9: test stream route
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- yaml_config
apisix:
  stream_proxy:
    tcp:
    - addr: 9100
plugin_attr:
  prometheus:
    export_addr:
      port: 1980
--- stream_request
mmm
--- stream_response eval
qr/400 Bad Request/



=== TEST 10: test service discovery
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- yaml_config
plugin_attr:
  prometheus:
    export_addr:
      port: 1980
discovery:
 dns:
   servers:
     - "127.0.0.1:8600"
   resolv_conf: /etc/resolv.conf
   order:
     - last
     - SRV
     - A
     - AAAA
     - CNAME
--- config
    location /t {
        content_by_lua_block {
            ngx.say("passed")
        }
    }
--- response_body
passed
--- log_level: info
--- error_log
discovery: dns init worker
discovery: nacos init worker
discovery: kubernetes init worker



=== TEST 11: retrieve ETCD config with extra header
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- yaml_config
apisix:
  id: ba5fe070
api7ee:
  telemetry:
    enable: false
--- config
    location /t {
        content_by_lua_block {
            ngx.say("ok")
        }
    }
--- log_level: info
--- error_log
conf for etcd updated, the extra header Gateway-Instance-ID: ba5fe070



=== TEST 12: request etcd with Gateway-Version header
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- config
    location /t {
        content_by_lua_block {
            ngx.say("ok")
        }
    }
--- log_level: info
--- error_log
"Gateway-Version":"3.2.2"



=== TEST 13: incompatible with the control plane version
--- extra_init_by_lua_start
    require("apisix.core.version").VERSION = "3.1.1"
    require "agent.hook";
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- config
    location /t {
        content_by_lua_block {
            ngx.say("ok")
        }
    }
--- error_log
gateway version not supported
