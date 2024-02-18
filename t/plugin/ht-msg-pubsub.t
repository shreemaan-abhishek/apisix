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
        enable_log_rotate: true
    ht-msg-sub:
        enable_log: true
        enable_log_rotate: true
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
                    ["ht-ws-msg-pub"] = {}
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



=== TEST 2: setup subroute for subscribe to topic incrementally
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t("/apisix/admin/routes/sub1", ngx.HTTP_PUT, [[
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
                        "action": "sub_add",
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



=== TEST 3: setup subroute for subscribe to topic in full
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
                        "action": "sub_put",
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
                "uri": "/60150/ormp/subscribe/syncSubscribe"
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



=== TEST 4: setup subroute for register
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



=== TEST 6: set metadata for plugin ht-ws-msg-pub
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



=== TEST 7: subscribe to topic in full and then subscribe to topic incrementally
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

            -- Subscribe in full
            local _, err = ws:send_text([[{
                "uri":"/60150/ormp/subscribe/syncSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "01321322",
                    "client-metadata": {}
                },
                "body":{
                    "topics":["hq_100001_123", "hq_100001_124", "hq_100001_125"]
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

            -- push a message to topic hq_100001_123
            local ok, stdout, stderr, reason, status = shell.run([[grpcurl -H 'topic: hq_100001_123' -H 'msgid: 1234' -plaintext -d '{"body":"cTEyMw=="}' 127.0.0.1:9110 pushserverpb.Push.Msg]], nil, 200)
            core.log.warn("hq_100001_123 ok: ", ok, " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)

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

            -- Subscribe incrementally
            local _, err = ws:send_text([[{
                "uri":"/60150/ormp/subscribe/accountSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "01321312",
                    "client-metadata": {}
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

            -- push a to topic hq_100001_129
            local ok, stdout, stderr, reason, status = shell.run([[grpcurl -H 'topic: hq_100001_129' -H 'msgid: 129' -plaintext -d '{"body":"cTEyOQ=="}' 127.0.0.1:9110 pushserverpb.Push.Msg]], nil, 200)
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

            -- push a to topic hq_100001_126
            local ok, stdout, stderr, reason, status = shell.run([[grpcurl -H 'topic: hq_100001_126' -H 'msgid: 126' -plaintext -d '{"body":"cTEyNg=="}' 127.0.0.1:9110 pushserverpb.Push.Msg]], nil, 200)
            core.log.warn("hq_100001_126 ok: ", ok, " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)

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

            -- push a to topic hq_100001_124
            local ok, stdout, stderr, reason, status = shell.run([[grpcurl -H 'topic: hq_100001_124' -H 'msgid: 124' -plaintext -d '{"body":"cTEyNA=="}' 127.0.0.1:9110 pushserverpb.Push.Msg]], nil, 200)
            core.log.warn("hq_100001_124 ok: ", ok, " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)

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
msgId: 01321322
message: upstream success
data:q123, topic:hq_100001_123
status: 200
msgId: 01321312
message: upstream success
data:q129, topic:hq_100001_129
data:q126, topic:hq_100001_126
data:q124, topic:hq_100001_124
--- timeout: 3s
--- wait: 2
--- error_log
hit the subroute: true



=== TEST 8: subscribe to topic incrementally and then subscribe to topic in full
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

            -- Subscribe incrementally
            local _, err = ws:send_text([[{
                "uri":"/60150/ormp/subscribe/accountSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "1111",
                    "client-metadata": {}
                },
                "body":{
                    "topics":["frontend-topic", "hq_100001_136"]
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

            -- push a to topic backend-topic
            local ok, stdout, stderr, reason, status = shell.run([[grpcurl -H 'topic: backend-topic' -H 'msgid: 139' -plaintext -d '{"body":"cTEzOQ=="}' 127.0.0.1:9110 pushserverpb.Push.Msg]], nil, 200)
            core.log.warn("backend-topic ok: ", ok, " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)

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


            -- push a to topic sig-test
            local ok, stdout, stderr, reason, status = shell.run([[grpcurl -H 'topic: sig-test' -H 'msgid: 139' -plaintext -d '{"body":"c2lnLXRlc3QtbXNn"}' 127.0.0.1:9110 pushserverpb.Push.Msg]], nil, 200)
            core.log.warn("sig-test ok: ", ok, " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)

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

            -- push a to topic hq_100001_136
            local ok, stdout, stderr, reason, status = shell.run([[grpcurl -H 'topic: hq_100001_136' -H 'msgid: 136' -plaintext -d '{"body":"cTEzNg=="}' 127.0.0.1:9110 pushserverpb.Push.Msg]], nil, 200)
            core.log.warn("hq_100001_136 ok: ", ok, " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)

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

            -- Subscribe in full
            local _, err = ws:send_text([[{
                "uri":"/60150/ormp/subscribe/syncSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "2222",
                    "client-metadata": {}
                },
                "body":{
                    "topics":["hq_100001_133", "hq_100001_136", "hq_100001_135"]
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

            -- push a to topic hq_100001_139
            local ok, stdout, stderr, reason, status = shell.run([[grpcurl -H 'topic: hq_100001_139' -H 'msgid: 139' -plaintext -d '{"body":"cTEzOQ=="}' 127.0.0.1:9110 pushserverpb.Push.Msg]], nil, 200)
            core.log.warn("hq_100001_139 ok: ", ok, " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)

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

            -- push a to topic hq_100001_136
            local ok, stdout, stderr, reason, status = shell.run([[grpcurl -H 'topic: hq_100001_136' -H 'msgid: 136' -plaintext -d '{"body":"cTEzNg=="}' 127.0.0.1:9110 pushserverpb.Push.Msg]], nil, 200)
            core.log.warn("hq_100001_136 ok: ", ok, " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)

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

            -- push a message to topic hq_100001_133
            local ok, stdout, stderr, reason, status = shell.run([[grpcurl -H 'topic: hq_100001_133' -H 'msgid: 133' -plaintext -d '{"body":"cTEzMw=="}' 127.0.0.1:9110 pushserverpb.Push.Msg]], nil, 200)
            core.log.warn("hq_100001_133 ok: ", ok, " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)

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
msgId: 1111
message: upstream success
data:q139, topic:backend-topic
data:sig-test-msg, topic:sig-test
data:q136, topic:hq_100001_136
status: 200
msgId: 2222
message: upstream success
failed to receive the frame
data:q136, topic:hq_100001_136
data:q133, topic:hq_100001_133
--- timeout: 3s
--- wait: 2
--- error_log
hit the subroute: true



=== TEST 9: success to register connection
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

            ws:send_text([[{
                "uri":"/60101/ormp/session/channelRegister",
                "header": {
                    "ts": 132132132,
                    "msgId": "1111",
                    "client-metadata": {}
                }
            }]])

            local raw_data, raw_type, err = ws:recv_frame()
            if not raw_data then
                ngx.exit(444)
            end

            local data = core.json.decode(raw_data)
            if not data then
                ngx.exit(444)
            end
            assert(type(data.body.resultData) == "table")
            assert(data.body.resultData.sid ~= nil)
            ngx.say("status: ", data.status)
            ngx.say("msgId: ", data.body.msgId)
            ngx.say("message: ", data.body.message)
            ngx.say("data.origin: ", data.body.resultData.origin)

            ws:close()
        }
    }
--- response_body
status: 200
msgId: 1111
message: upstream success
data.origin: null



=== TEST 10: verify messages written to the log
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

            -- Subscribe incrementally
            local _, err = ws:send_text([[{
                "uri":"/60150/ormp/subscribe/accountSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "1111",
                    "client-metadata": {}
                },
                "body":{
                    "topics":["hq_100001_139", "hq_100001_136"]
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

            -- Subscribe in full
            local _, err = ws:send_text([[{
                "uri":"/60150/ormp/subscribe/syncSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "2222",
                    "client-metadata": {}
                },
                "body":{
                    "topics":["hq_100001_139", "hq_100001_136", "hq_100001_135"]
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

            -- push a to topic hq_100001_139
            local ok, stdout, stderr, reason, status = shell.run([[grpcurl -H 'topic: hq_100001_139' -H 'msgid: 139' -plaintext -d '{"body":"cTEzOQ=="}' 127.0.0.1:9110 pushserverpb.Push.Msg]], nil, 200)
            core.log.warn("hq_100001_139 ok: ", ok, " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)

            ngx.sleep(1)

            local path = ngx.config.prefix() .. "/logs/ht_msg_sub.log"
            local path2 = ngx.config.prefix() .. "/logs/ht_msg_push.log"
            local fd, err = io.open(path2, 'r')
            if not fd then
                core.log.error("failed to open file: file.log, error info: ", err)
                return
            end

            local msg = fd:read("*a")
            ngx.print(msg)

            local fd, err = io.open(path, 'r')
            if not fd then
                core.log.error("failed to open file: file.log, error info: ", err)
                return
            end

            local msg = fd:read("*a")
            ngx.print(msg)
            ws:close()
        }
    }
--- error_log
--- response_body eval
qr{Push Message(?s).*\"q139\"(?s).*Subscribe Topics.*(?s).*Subscribe Topics}



=== TEST 11: verify messages written to the log with append_str
--- extra_yaml_config
plugins:
    - ht-ws-msg-pub
    - ht-msg-sub
plugin_attr:
    ht-ws-msg-pub:
        enable_log: true
        log_append_str: "pub-append-str"
        enable_log_rotate: false
    ht-msg-sub:
        enable_log: true
        log_append_str: "sub-append-str"
        enable_log_rotate: false
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
            ws:set_timeout(2000)

            -- Subscribe incrementally
            local _, err = ws:send_text([[{
                "uri":"/60150/ormp/subscribe/accountSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "1111",
                    "client-metadata": {}
                },
                "body":{
                    "topics":["hq_100001_139", "hq_100001_136"]
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

            -- push a to topic hq_100001_139
            local ok, stdout, stderr, reason, status = shell.run([[grpcurl -H 'topic: hq_100001_139' -H 'msgid: 139' -plaintext -d '{"body":"cTEzOQ=="}' 127.0.0.1:9110 pushserverpb.Push.Msg]], nil, 200)
            core.log.warn("hq_100001_139 ok: ", ok, " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)

            ngx.sleep(1)

            local path = ngx.config.prefix() .. "/logs/ht_msg_sub.log"
            local path2 = ngx.config.prefix() .. "/logs/ht_msg_push.log"
            local fd, err = io.open(path2, 'r')
            if not fd then
                core.log.error("failed to open file: file.log, error info: ", err)
                return
            end

            local msg = fd:read("*a")
            ngx.print(msg)

            local fd, err = io.open(path, 'r')
            if not fd then
                core.log.error("failed to open file: file.log, error info: ", err)
                return
            end

            local msg = fd:read("*a")
            ngx.print(msg)
            ws:close()
        }
    }
--- error_log
--- response_body eval
qr{Push Message(?s).*\"q139\".*pub-append-str(?s).*Subscribe Topics.*sub-append-str}
