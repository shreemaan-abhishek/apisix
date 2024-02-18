use Cwd qw(cwd);
use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_root_location();

my $apisix_home = $ENV{APISIX_HOME} // cwd();

add_block_preprocessor(sub {
    my ($block) = @_;

    $block->set_value("stream_conf_enable", 1);

    if (!defined $block->extra_stream_config) {
        my $stream_config = <<_EOC_;
    server {
        listen 1975;
        content_by_lua_block {
            require("lib.mock_ms1975").start()
        }
    }
_EOC_
        $block->set_value("extra_stream_config", $stream_config);
    }

    my $extra_yaml_config = $block->extra_yaml_config // <<_EOC_;
plugins:
    - ht-ws-msg-pub
    - ht-msg-sub
    - prometheus
    - public-api
plugin_attr:
    ht-ws-msg-pub:
        enable_log: true
        enable_log_rotate: false
    ht-msg-sub:
        enable_log: true
        enable_log_rotate: false
_EOC_

    $block->set_value("extra_yaml_config", $extra_yaml_config);

    if (!defined $block->request) {
        $block->set_value("request", "GET /t");
    }
});

run_tests();

__DATA__

=== TEST 1: setup route with plugin ht-ws-msg-pub
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test

            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                {
                    uri = "/apisix/prometheus/metrics",
                    plugins = {
                        ["public-api"] = {}
                    }
                }
            )
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            local code, body = t("/apisix/admin/routes/ht_ws", ngx.HTTP_PUT, {
                plugins = {
                    ["prometheus"] = {},
                    ["ht-ws-msg-pub"] = {
                        disconnect_notify_urls = {
                            "/60101/ormp/session/channelDisconnect"
                        },
                    },
                },
                uri = "/ht_ws"
            })
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 2: set metadata for plugin ht-ws-msg-pub
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t("/apisix/admin/plugin_metadata/ht-ws-msg-pub", ngx.HTTP_PUT, {
                api7_push_gateway_addrs = {
                    "ws://127.0.0.1:9110/websocket"
                }
            })
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 3: setup subroute for subscribe
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t("/apisix/admin/routes/sub1", ngx.HTTP_PUT, [[
            {
                "labels": {
                    "superior_id": "ht_ws"
                },
                "plugins": {
                    "ht-msg-sub": {
                        "action": "sub_add",
                        "upstream": {
                            "nodes": [
                                {
                                    "host": "127.0.0.1",
                                    "port": 1975,
                                    "weight": 1
                                }
                            ],
                            "type": "roundrobin"
                        }
                    }
                },
                "uri": "/60150/ormp/subscribe/accountSubscribe"
            }
            ]])
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 4: setup subroute for proxy
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t("/apisix/admin/routes/12", ngx.HTTP_PUT, [[
            {
                "labels": {
                    "superior_id": "ht_ws"
                },
                "plugins": {
                    "ht-msg-sub": {
                        "action": "proxy",
                        "upstream": {
                            "nodes": [{
                                "host": "127.0.0.1",
                                "port": 1975,
                                "weight": 1
                            }],
                            "timeout": {
                                "connect": 5,
                                "send": 0.5,
                                "read": 0.5
                            },
                            "type": "roundrobin"
                        }
                    }
                },
                "uri": "/60101/ormp/query"
            }
            ]])
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 5: setup subroute for disconnect
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t("/apisix/admin/routes/sub4", ngx.HTTP_PUT, [[
            {
                 "upstream": {
                    "nodes": {
                        "127.0.0.1:1980": 1
                    },
                    "type": "none"
                },
                "labels": {
                    "superior_id": "ht_ws"
                },
                "plugins": {
                    "ht-msg-sub": {
                        "action": "disconnect",
                        "headers": {
                            "add":{
                                "_url_segment": "3"
                            }
                        },
                        "upstream": {
                            "nodes": [{
                                "host": "127.0.0.1",
                                "port": 1975,
                                "weight": 1
                            }],
                            "type": "roundrobin"
                        }
                    }
                },
                "uri": "/60101/ormp/session/channelDisconnect"
            }
            ]])
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 6: prometheus plugin by global rule
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local _, body = t("/apisix/admin/global_rules/1", ngx.HTTP_PUT, [[{
                "plugins": {
                    "prometheus": {}
                },
                "upstream": {
                    "nodes": {
                        "127.0.0.1:1980": 1
                    },
                    "type": "roundrobin"
                },
                "uri": "/hello"
            }]])

            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 7: two connections
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local core   = require("apisix.core")
            local shell = require "resty.shell"

            local ws_client = require "resty.websocket.client"
            local ws = ws_client:new()
            local ok, err = ws:connect("ws://127.0.0.1:1984/ht_ws")
            if not ok then
                ngx.log(ngx.ERR, "failed to connect: "..err)
            end
            ws:set_timeout(1000)

            -- subscribe topics
            local _, err = ws:send_text([[{
                "uri":"/60150/ormp/subscribe/accountSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "1"
                },
                "body":{
                    "topics":["hq_100001_129", "hq_100001_126"]
                }
            }]])

            if err then
                ngx.log(ngx.ERR, "failed to send text: "..err)
                ngx.exit(444)
            end

            -- receive the result of subscription
            local raw_data, raw_type, err = ws:recv_frame()
            if not raw_data then
                ngx.log(ngx.ERR, "failed to receive the frame: ", err)
                ngx.exit(444)
            end

            local data = core.json.decode(raw_data)
            if data then
                ngx.say("status: ", data.status)
                ngx.say("msgId: ", data.body.msgId)
                ngx.say("message: ", data.body.message)
            end

            --- client2
            local ws2 = ws_client:new()
            local ok, err = ws2:connect("ws://127.0.0.1:1984/ht_ws")
            if not ok then
                ngx.log(ngx.ERR, "failed to connect: "..err)
            end

            -- Subscribe incrementally
            local _, err = ws2:send_text([[{
                "uri":"/60150/ormp/subscribe/accountSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "2"
                },
                "body":{
                    "topics":["hq_100001_129", "hq_100001_127"]
                }
            }]])

            if err then
                ngx.log(ngx.ERR, "failed to send text: "..err)
                ngx.exit(444)
            end

            -- receive the result of subscription
            local raw_data, raw_type, err = ws2:recv_frame()
            if not raw_data then
                ngx.log(ngx.ERR, "failed to receive the frame: ", err)
                ngx.exit(444)
            end

            local data = core.json.decode(raw_data)
            if data then
                ngx.say("status: ", data.status)
                ngx.say("msgId: ", data.body.msgId)
                ngx.say("message: ", data.body.message)
            end

            -- push a to topic hq_100001_129
            local ok, stdout, stderr, reason, status = shell.run([[grpcurl -H 'topic: hq_100001_129' -H 'msgid: 1291' -plaintext -d '{"body":"cTEyOQ=="}' 127.0.0.1:9110 pushserverpb.Push.Msg]], nil, 200)
            core.log.warn("hq_100001_129 ok: ", ok, " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)

            -- receive the push message
            if ok then
                local raw_data = ws:recv_frame()
                if raw_data then
                    local data = core.json.decode(raw_data)
                    ngx.say("client1 received data:" .. data.body.resultData .. ", topic:" .. data.body.topic)
                else
                    ngx.say("failed to receive the frame")
                end

                local raw_data = ws2:recv_frame()
                if raw_data then
                    local data = core.json.decode(raw_data)
                    ngx.say("client2 received data:" .. data.body.resultData .. ", topic:" .. data.body.topic)
                else
                    ngx.say("failed to receive the frame")
                end
            end

            ws:close()

            local code, _, res_data = t("/apisix/prometheus/metrics", ngx.HTTP_GET, nil)
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(res_data)
        }
    }
--- response_body eval
qr/apisix_ws_current_connections\{route="ht_ws"\} 1/ and
qr/apisix_ws_pub_total\{topic="hq_100001_129"\} 2/ and
qr/apisix_ws_status\{route="ht_ws",subroute="sub1",status="200"\} 2/ and
qr/apisix_ws_latency_count\{route="ht_ws",subroute="sub1"\} 2/ and
qr/apisix_ws_upstream_latency_count\{route="ht_ws",subroute="sub1"\} 2/
--- timeout: 6s



=== TEST 8: disable metrics by metadata
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t("/apisix/admin/plugin_metadata/ht-ws-msg-pub", ngx.HTTP_PUT, {
                api7_push_gateway_addrs = {
                    "ws://127.0.0.1:9110/websocket"
                },
                metrics_enabled = false,
            })
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 9: check metrics disabled by metadata
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local core   = require("apisix.core")
            local shell = require "resty.shell"

            local ws_client = require "resty.websocket.client"
            local ws = ws_client:new()
            local ok, err = ws:connect("ws://127.0.0.1:1984/ht_ws")
            if not ok then
                ngx.log(ngx.ERR, "failed to connect: "..err)
            end
            ws:set_timeout(1000)

            -- subscribe topics
            local _, err = ws:send_text([[{
                "uri":"/60150/ormp/subscribe/accountSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "1"
                },
                "body":{
                    "topics":["hq_100001_129", "hq_100001_126"]
                }
            }]])

            if err then
                ngx.log(ngx.ERR, "failed to send text: "..err)
                ngx.exit(444)
            end

            -- receive the result of subscription
            local raw_data, raw_type, err = ws:recv_frame()
            if not raw_data then
                ngx.log(ngx.ERR, "failed to receive the frame: ", err)
                ngx.exit(444)
            end

            local data = core.json.decode(raw_data)
            if data then
                ngx.say("status: ", data.status)
                ngx.say("msgId: ", data.body.msgId)
                ngx.say("message: ", data.body.message)
            end

            ws:close()

            local code, _, res_data = t("/apisix/prometheus/metrics", ngx.HTTP_GET, nil)
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(res_data)
        }
    }
--- response_body_like
^((?!apisix_ws_current_connections).)*$
--- timeout: 6s



=== TEST 10: metrics upstream latency for ms1975
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test

            -- hit the route to trigger the metrics
            t("/60101/ormp/query", ngx.HTTP_GET, nil)

            local code, _, res_data = t("/apisix/prometheus/metrics", ngx.HTTP_GET, nil)
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(res_data)
        }
    }
--- response_body eval
qr/apisix_http_latency_bucket\{type="upstream",route="12",service="",consumer="",node="127.0.0.1",le="500"\} 1/
