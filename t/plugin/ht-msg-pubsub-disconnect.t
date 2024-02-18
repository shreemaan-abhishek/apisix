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
                            "/60101/ormp/session/channelDisconnect",
                            "/1001/ormp/session/channelDisconnect"
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



=== TEST 3: setup subroute for register
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t("/apisix/admin/routes/sub3", ngx.HTTP_PUT, [[
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
                        "action": "register",
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
                "uri": "/60101/ormp/session/channelRegister"
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



=== TEST 4: setup subroute for subscribe
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



=== TEST 6: actively disconnect
--- config
    location /t {
        content_by_lua_block {
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

            -- wait for push gateway update
            ngx.sleep(0.2)

            -- push a to topic hq_100001_129
            local ok, stdout, stderr, reason, status = shell.run([[grpcurl -H 'topic: hq_100001_129' -H 'msgid: 1291' -plaintext -d '{"body":"cTEyOQ=="}' 127.0.0.1:9110 pushserverpb.Push.Msg]], nil, 200)
            core.log.warn("hq_100001_129 ok: ", ok, " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)

            -- receive the push message
            if ok then
                local raw_data = ws:recv_frame()
                if raw_data then
                    local data = core.json.decode(raw_data)
                    ngx.say("data:" .. data.body.resultData .. ", topic:" .. data.body.topic)
                else
                    ngx.say("failed to receive the frame")
                end
            end

            -- check the connections of push gateway
            local http = require "resty.http"
            local uri = "http://127.0.0.1:9110/list/topics"
            local httpc = http.new()
            httpc:set_timeout(1000)
            local res, err = httpc:request_uri(uri, {method = "GET", keepalive = false})
            if res then
                local msg = core.json.decode(res.body)
                ngx.say("topics: ", #msg.topics)
            end

            --- send close
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

            -- receive the result of closing
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

            -- check the connections of push gateway
            local http = require "resty.http"
            local uri = "http://127.0.0.1:9110/list/topics"
            local httpc = http.new()
            httpc:set_timeout(1000)
            local res, err = httpc:request_uri(uri, {method = "GET", keepalive = false})
            if res then
                local msg = core.json.decode(res.body)
                ngx.say("topics: ", #msg.topics)
            end

            -- push a to topic hq_100001_129
            local ok, stdout, stderr, reason, status = shell.run([[grpcurl -H 'topic: hq_100001_129' -H 'msgid: 1292' -plaintext -d '{"body":"cTEyOQ=="}' 127.0.0.1:9110 pushserverpb.Push.Msg]], nil, 200)
            core.log.warn("hq_100001_129 ok: ", ok, " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)

            -- receive the push message
            if ok then
                local raw_data = ws:recv_frame()
                if raw_data then
                    local data = core.json.decode(raw_data)
                    ngx.say("data:" .. data.body.resultData .. ", topic:" .. data.body.topic)
                else
                    ngx.say("failed to receive the frame")
                end
            end

            ws:close()
        }
    }
--- response_body
status: 200
msgId: 1
message: upstream success
data:q129, topic:hq_100001_129
topics: 2
status: 200
msgId: 10
message: upstream success
topics: 0
failed to receive the frame
--- timeout: 6s
--- error_log
upstream received _url_segment: 3
--- no_error_log
report client closing info to:



=== TEST 7: passive disconnect
--- config
    location /t {
        content_by_lua_block {
            local core   = require("apisix.core")
            local shell = require "resty.shell"

            local ws_client = require "resty.websocket.client"
            local ws = ws_client:new()
            local ok, err = ws:connect("ws://127.0.0.1:1984/ht_ws")
            if not ok then
                ngx.log(ngx.ERR, "failed to connect: "..err)
            end
            ws:set_timeout(1000)

            local _, err = ws:send_text([[{
                "uri":"/60101/ormp/session/channelRegister",
                "header": {
                    "ts": 132132132,
                    "msgId": "11"
                }
            }]])

            local raw_data, raw_type, err = ws:recv_frame()
            if not raw_data then
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

            -- check the connections of push gateway - registered
            local http = require "resty.http"
            local uri = "http://127.0.0.1:9110/list/topics"
            local httpc = http.new()
            httpc:set_timeout(1000)
            local res, err = httpc:request_uri(uri, {method = "GET", keepalive = false})
            if res then
                local msg = core.json.decode(res.body)
                ngx.say("registered, topics: ", #msg.topics)
            end

            -- subscribe topics
            local _, err = ws:send_text([[{
                "uri":"/60150/ormp/subscribe/accountSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "12"
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

            -- wait for push gateway update
            ngx.sleep(0.2)

            -- check the connections of push gateway - subscribed
            local http = require "resty.http"
            local uri = "http://127.0.0.1:9110/list/topics"
            local httpc = http.new()
            httpc:set_timeout(1000)
            local res, err = httpc:request_uri(uri, {method = "GET", keepalive = false})
            if res then
                local msg = core.json.decode(res.body)
                ngx.say("subscribed, topics: ", #msg.topics)
            end

            -- push a to topic hq_100001_129
            local ok, stdout, stderr, reason, status = shell.run([[grpcurl -H 'topic: hq_100001_129' -H 'msgid: 1291' -plaintext -d '{"body":"cTEyOQ=="}' 127.0.0.1:9110 pushserverpb.Push.Msg]], nil, 200)
            core.log.warn("hq_100001_129 ok: ", ok, " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)

            -- receive the push message
            if ok then
                local raw_data = ws:recv_frame()
                if raw_data then
                    local data = core.json.decode(raw_data)
                    ngx.say("data:" .. data.body.resultData .. ", topic:" .. data.body.topic)
                else
                    ngx.say("failed to receive the frame")
                end
            end

            ws:close()

            -- wait for push gateway update
            ngx.sleep(0.2)

            -- check the connections of push gateway - closed
            local http = require "resty.http"
            local uri = "http://127.0.0.1:9110/list/topics"
            local httpc = http.new()
            httpc:set_timeout(1000)
            local res, err = httpc:request_uri(uri, {method = "GET", keepalive = false})
            if res then
                local msg = core.json.decode(res.body)
                ngx.say("client closed, topics: ", #msg.topics)
            end
        }
    }
--- response_body
status: 200
msgId: 11
message: upstream success
registered, topics: 1
status: 200
msgId: 12
message: upstream success
subscribed, topics: 3
data:q129, topic:hq_100001_129
client closed, topics: 0
--- timeout: 6s
--- error_log
upstream received _url_segment: 3
report client closing info to:
