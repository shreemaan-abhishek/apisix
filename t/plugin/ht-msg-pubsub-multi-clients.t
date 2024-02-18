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
            local code, body = t("/apisix/admin/routes/ht_ws", ngx.HTTP_PUT, {
                plugins = {
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



=== TEST 4: setup subroute for delete topic
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t("/apisix/admin/routes/sub2", ngx.HTTP_PUT, [[
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
                        "action": "sub_delete",
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
                "uri": "/60150/ormp/subscribe/cancelSubscribe"
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



=== TEST 6: subscribe topic and receive push message by multi clients
--- config
    location /t {
        content_by_lua_block {
            local core   = require("apisix.core")
            local shell = require "resty.shell"

            ----- client1
            local ws_client = require "resty.websocket.client"
            local ws = ws_client:new()
            local ok, err = ws:connect("ws://127.0.0.1:1984/ht_ws")
            if not ok then
                ngx.log(ngx.ERR, "failed to connect: "..err)
            end

            -- Subscribe incrementally
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

            -- wait for push gateway update
            ngx.sleep(0.2)

            -- check the connections of push gateway - client1 and client2 subscribed
            local http = require "resty.http"
            local uri = "http://127.0.0.1:9110/list/topics"
            local httpc = http.new()
            httpc:set_timeout(1000)
            local res, err = httpc:request_uri(uri, {method = "GET", keepalive = false})
            if res then
                local msg = core.json.decode(res.body)
                ngx.say("client1 and client2 subscribed topics: ", #msg.topics)
            end

            -- push a to topic hq_100001_129
            local ok, stdout, stderr, reason, status = shell.run([[grpcurl -H 'topic: hq_100001_129' -H 'msgid: 1291' -plaintext -d '{"body":"cTEyOQ=="}' 127.0.0.1:9110 pushserverpb.Push.Msg]], nil, 200)
            core.log.warn("hq_100001_129 ok: ", ok, " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)

            -- cliet1 receive the push message
            if ok then
                local raw_data = ws:recv_frame()
                if raw_data then
                    local data = core.json.decode(raw_data)
                    ngx.say("client1 received data:" .. data.body.resultData .. ", topic:" .. data.body.topic)
                else
                    ngx.say("failed to receive the frame")
                end
            end

            -- cliet2 receive the push message
            if ok then
                local raw_data = ws2:recv_frame()
                if raw_data then
                    local data = core.json.decode(raw_data)
                    ngx.say("client2 received data:" .. data.body.resultData .. ", topic:" .. data.body.topic)
                else
                    ngx.say("failed to receive the frame")
                end
            end

            --- client1 close
            local _, err = ws:send_text([[{
                "uri":"/60101/ormp/session/channelDisconnect",
                "header": {
                    "ts": 132132132,
                    "msgId": "10"
                }
            }]])

            if err then
                ngx.log(ngx.ERR, "failed to send disconnect: "..err)
                ngx.exit(444)
            end
            ws:close()

            -- wait for push gateway update
            ngx.sleep(0.2)

            -- check the connections of push gateway - client1 closed, client2 subscribed only
            local http = require "resty.http"
            local uri = "http://127.0.0.1:9110/list/topics"
            local httpc = http.new()
            httpc:set_timeout(1000)
            local res, err = httpc:request_uri(uri, {method = "GET", keepalive = false})
            if res then
                local msg = core.json.decode(res.body)
                ngx.say("only client2 subscribed topics: ", #msg.topics)
            end

            -- push a to topic hq_100001_129
            local ok, stdout, stderr, reason, status = shell.run([[grpcurl -H 'topic: hq_100001_129' -H 'msgid: 1292' -plaintext -d '{"body":"cTEyOQ=="}' 127.0.0.1:9110 pushserverpb.Push.Msg]], nil, 200)
            core.log.warn("hq_100001_129 ok: ", ok, " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)

            -- cliet2 receive the push message
            if ok then
                local raw_data = ws2:recv_frame()
                if raw_data then
                    local data = core.json.decode(raw_data)
                    ngx.say("client2 received data:" .. data.body.resultData .. ", topic:" .. data.body.topic)
                else
                    ngx.say("failed to receive the frame")
                end
            end

            --- client3
            local ws3 = ws_client:new()
            local ok, err = ws3:connect("ws://127.0.0.1:1984/ht_ws")
            if not ok then
                ngx.log(ngx.ERR, "failed to connect: "..err)
            end

            -- Subscribe incrementally
            local _, err = ws3:send_text([[{
                "uri":"/60150/ormp/subscribe/accountSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "3"
                },
                "body":{
                    "topics":["hq_100001_129", "hq_100001_128"]
                }
            }]])

            if err then
                ngx.log(ngx.ERR, "failed to send text: "..err)
                ngx.exit(444)
            end

            -- receive the result of subscription
            local raw_data, raw_type, err = ws3:recv_frame()
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

            -- wait for push gateway update
            ngx.sleep(0.2)

            -- check the connections of push gateway - client2 and client3 subscribed
            local http = require "resty.http"
            local uri = "http://127.0.0.1:9110/list/topics"
            local httpc = http.new()
            httpc:set_timeout(1000)
            local res, err = httpc:request_uri(uri, {method = "GET", keepalive = false})
            if res then
                local msg = core.json.decode(res.body)
                ngx.say("client2 and client3 subscribed topics: ", #msg.topics)
            end

            -- push a to topic hq_100001_129
            local ok, stdout, stderr, reason, status = shell.run([[grpcurl -H 'topic: hq_100001_129' -H 'msgid: 1293' -plaintext -d '{"body":"cTEyOQ=="}' 127.0.0.1:9110 pushserverpb.Push.Msg]], nil, 200)
            core.log.warn("hq_100001_129 ok: ", ok, " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)

            -- cliet2 receive the push message
            if ok then
                local raw_data = ws2:recv_frame()
                if raw_data then
                    local data = core.json.decode(raw_data)
                    ngx.say("client2 received data:" .. data.body.resultData .. ", topic:" .. data.body.topic)
                else
                    ngx.say("failed to receive the frame")
                end
            end

            -- cliet3 receive the push message
            if ok then
                local raw_data = ws3:recv_frame()
                if raw_data then
                    local data = core.json.decode(raw_data)
                    ngx.say("client3 received data:" .. data.body.resultData .. ", topic:" .. data.body.topic)
                else
                    ngx.say("failed to receive the frame")
                end
            end

            --- client2 delete topic hq_100001_129
            local _, err = ws2:send_text([[{
                "uri":"/60150/ormp/subscribe/cancelSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "21"
                },
                "body":{
                    "topics":["hq_100001_129"]
                }
            }]])
            if err then
                ngx.log(ngx.ERR, "failed to send disconnect: "..err)
                ngx.exit(444)
            end

            -- receive the result of delete subscription
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

            -- wait for push gateway update
            ngx.sleep(0.2)

            -- check the connections of push gateway - client2 and client3 subscribed, client2 delete topic hq_100001_129
            local http = require "resty.http"
            local uri = "http://127.0.0.1:9110/list/topics"
            local httpc = http.new()
            httpc:set_timeout(1000)
            local res, err = httpc:request_uri(uri, {method = "GET", keepalive = false})
            if res then
                local msg = core.json.decode(res.body)
                ngx.say("client2 delete topic hq_100001_129, client2 and client3 subscribed topics: ", #msg.topics)
            end

            -- push a to topic hq_100001_127
            local ok, stdout, stderr, reason, status = shell.run([[grpcurl -H 'topic: hq_100001_127' -H 'msgid: 127' -plaintext -d '{"body":"cTEyNw=="}' 127.0.0.1:9110 pushserverpb.Push.Msg]], nil, 200)
            core.log.warn("hq_100001_127 ok: ", ok, " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)

            -- cliet2 receive the push message
            if ok then
                local raw_data = ws2:recv_frame()
                if raw_data then
                    local data = core.json.decode(raw_data)
                    ngx.say("client2 received data:" .. data.body.resultData .. ", topic:" .. data.body.topic)
                else
                    ngx.say("failed to receive the frame")
                end
            end

            -- push a to topic hq_100001_129
            local ok, stdout, stderr, reason, status = shell.run([[grpcurl -H 'topic: hq_100001_129' -H 'msgid: 1294' -plaintext -d '{"body":"cTEyOQ=="}' 127.0.0.1:9110 pushserverpb.Push.Msg]], nil, 200)
            core.log.warn("hq_100001_129 ok: ", ok, " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)
            -- cliet3 receive the push message
            if ok then
                local raw_data = ws3:recv_frame()
                if raw_data then
                    local data = core.json.decode(raw_data)
                    ngx.say("client3 received data:" .. data.body.resultData .. ", topic:" .. data.body.topic)
                else
                    ngx.say("failed to receive the frame")
                end
            end

            --- client2 close
            local _, err = ws2:send_text([[{
                "uri":"/60101/ormp/session/channelDisconnect",
                "header": {
                    "ts": 132132132,
                    "msgId": "20",
                    "client-metadata": {}
                }
            }]])

            if err then
                ngx.log(ngx.ERR, "failed to send disconnect: "..err)
                ngx.exit(444)
            end
            ws2:close()

            -- wait for push gateway update
            ngx.sleep(0.2)

            -- check the connections of push gateway - client2 closed and client3 subscribed only
            local http = require "resty.http"
            local uri = "http://127.0.0.1:9110/list/topics"
            local httpc = http.new()
            httpc:set_timeout(1000)
            local res, err = httpc:request_uri(uri, {method = "GET", keepalive = false})
            if res then
                local msg = core.json.decode(res.body)
                ngx.say("only client3 subscribed topics: ", #msg.topics)
            end

            -- push a to topic hq_100001_129
            local ok, stdout, stderr, reason, status = shell.run([[grpcurl -H 'topic: hq_100001_129' -H 'msgid: 1294' -plaintext -d '{"body":"cTEyOQ=="}' 127.0.0.1:9110 pushserverpb.Push.Msg]], nil, 200)
            core.log.warn("hq_100001_129 ok: ", ok, " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)

            -- cliet3 receive the push message
            if ok then
                local raw_data = ws3:recv_frame()
                if raw_data then
                    local data = core.json.decode(raw_data)
                    ngx.say("client3 received data:" .. data.body.resultData .. ", topic:" .. data.body.topic)
                else
                    ngx.say("failed to receive the frame")
                end
            end

            ws3:close()

            -- wait for push gateway update
            ngx.sleep(0.2)

            -- check the connections of push gateway - all clients closed
            local http = require "resty.http"
            local uri = "http://127.0.0.1:9110/list/topics"
            local httpc = http.new()
            httpc:set_timeout(1000)
            local res, err = httpc:request_uri(uri, {method = "GET", keepalive = false})
            if res then
                local msg = core.json.decode(res.body)
                ngx.say("all clients closed, topics: ", #msg.topics)
            end
        }
    }
--- response_body
status: 200
msgId: 1
message: upstream success
status: 200
msgId: 2
message: upstream success
client1 and client2 subscribed topics: 3
client1 received data:q129, topic:hq_100001_129
client2 received data:q129, topic:hq_100001_129
only client2 subscribed topics: 2
client2 received data:q129, topic:hq_100001_129
status: 200
msgId: 3
message: upstream success
client2 and client3 subscribed topics: 3
client2 received data:q129, topic:hq_100001_129
client3 received data:q129, topic:hq_100001_129
status: 200
msgId: 21
message: upstream success
client2 delete topic hq_100001_129, client2 and client3 subscribed topics: 3
client2 received data:q127, topic:hq_100001_127
client3 received data:q129, topic:hq_100001_129
only client3 subscribed topics: 2
client3 received data:q129, topic:hq_100001_129
all clients closed, topics: 0
--- timeout: 6s
