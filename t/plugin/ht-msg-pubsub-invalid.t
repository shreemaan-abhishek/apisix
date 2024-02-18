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
        log_rotate:
            interval: 1
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



=== TEST 3: setup subroute for subscribe with multiple upstreams
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
                                },
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



=== TEST 4: setup subroute for register
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t("/apisix/admin/routes/sub3", ngx.HTTP_PUT, [[
            {
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



=== TEST 5: setup subroute for subscribe to topic in full
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



=== TEST 6: schema for plugin ht-msg-sub test - no action
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
            ngx.print(body)
        }
    }
--- response_body
{"error_msg":"failed to check the configuration of plugin ht-msg-sub err: property \"action\" is required"}
--- error_code: 400



=== TEST 7: schema for plugin ht-msg-sub test - no upstream
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
                        "action": "sub_add"
                    }
                },
                "uri": "/60150/ormp/subscribe/accountSubscribe"
            }
            ]])
            if code >= 300 then
                ngx.status = code
            end
            ngx.print(body)
        }
    }
--- response_body
{"error_msg":"failed to check the configuration of plugin ht-msg-sub err: property \"upstream\" is required"}
--- error_code: 400



=== TEST 8: upstream error code test - ignore
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

            -- proxy query - upstream response error
            local _, err = ws:send_text([[{
                "uri":"/60150/ormp/subscribe/accountSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "11",
                    "wanted_code": "1"
                },
                "body":{
                    "topics":["hq_100001_129", "hq_100001_126"]
                }
            }]])

            if err then
                ngx.log(ngx.ERR, "failed to send text: "..err)
                ngx.exit(444)
            end

            -- receive the result of the query
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
        }
    }
--- response_body
status: 200
msgId: 11
message: wanted code: 1
--- timeout: 3s
--- error_log
building sid topic relation



=== TEST 9: upstream error code test - not save sid-topic relation
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

            -- proxy query - upstream response error
            local _, err = ws:send_text([[{
                "uri":"/60150/ormp/subscribe/accountSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "11",
                    "wanted_code": "1001"
                },
                "body":{
                    "topics":["hq_100001_129", "hq_100001_126"]
                }
            }]])

            if err then
                ngx.log(ngx.ERR, "failed to send text: "..err)
                ngx.exit(444)
            end

            -- receive the result of the query
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
        }
    }
--- response_body
status: 200
msgId: 11
message: wanted code: 1001
--- timeout: 3s
--- no_error_log
building sid topic relation
--- error_log
failed to request upstream



=== TEST 10: upstream error code test - not save sid-topic relation and close connection
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

            -- proxy query - upstream response error
            local _, err = ws:send_text([[{
                "uri":"/60150/ormp/subscribe/accountSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "11",
                    "wanted_code": "2001"
                },
                "body":{
                    "topics":["hq_100001_129", "hq_100001_126"]
                }
            }]])

            if err then
                ngx.log(ngx.ERR, "failed to send text: "..err)
                ngx.exit(444)
            end

            -- receive the result of the query
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
            ngx.say("raw_type: ", raw_type)
            ws:close()
        }
    }
--- response_body
status: 401
msgId: 11
message: wanted code: 2001
raw_type: close
--- timeout: 3s
--- no_error_log
building sid topic relation
--- error_log
failed to request upstream



=== TEST 11: invalid req body
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

            -- invalid req body - string
            local _, err = ws:send_text([[{
                "uri":"/60101/ormp/session/channelRegister",
                "header": {
                    "ts": 132132132,
                    "msgId": "1"
                },
                "body": "khkh"
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

            -- invalid req body - null
            local _, err = ws:send_text([[{
                "uri":"/60150/ormp/subscribe/accountSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "2"
                },
                "body": null
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

            -- invalid req body - nubmer
            local _, err = ws:send_text([[{
                "uri":"/60150/ormp/subscribe/accountSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "3"
                },
                "body": 1.1
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

            -- subscribe topic hq_100001_129 and hq_100001_126
            local _, err = ws:send_text([[{
                "uri":"/60150/ormp/subscribe/accountSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "11"
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

            -- sub_put with empty body
            local _, err = ws:send_text([[{
                "uri":"/60150/ormp/subscribe/syncSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "12"
                },
                "body":{}
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

            -- sub_put with invalid topic
            local _, err = ws:send_text([[{
                "uri":"/60150/ormp/subscribe/syncSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "13"
                },
                "body":{
                    "topic": 1.1
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

            -- sub_put with empty topic
            local _, err = ws:send_text([[{
                "uri":"/60150/ormp/subscribe/syncSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "14"
                },
                "body":{
                     "topics": []
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
        }
    }
--- response_body
status: 200
msgId: 1
message: upstream success
status: 400
msgId: 2
message: invalid body
status: 400
msgId: 3
message: invalid body
status: 200
msgId: 11
message: upstream success
data:q129, topic:hq_100001_129
status: 400
msgId: 12
message: invalid body
status: 400
msgId: 13
message: invalid body
status: 200
msgId: 14
message: upstream success
failed to receive the frame
--- timeout: 3s



=== TEST 12: invalid req header
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

            -- invalid req header - string
            local _, err = ws:send_text([[{
                "uri":"/60101/ormp/session/channelRegister",
                "header": "asdfasf"
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
                ngx.say("message: ", data.body.message)
            end

            -- invalid req header - null
            local _, err = ws:send_text([[{
                "uri":"/60101/ormp/session/channelRegister",
                "header": null
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
                ngx.say("message: ", data.body.message)
            end

            -- invalid req header - nubmer
            local _, err = ws:send_text([[{
                "uri":"/60101/ormp/session/channelRegister",
                "header": 1.1
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
                ngx.say("message: ", data.body.message)
            end

            ws:close()
        }
    }
--- response_body
status: 200
message: upstream success
status: 200
message: upstream success
status: 200
message: upstream success
--- timeout: 3s



=== TEST 13: invalid req uri
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

            -- invalid req uri - null
            local _, err = ws:send_text([[{
                "uri": null,
                "header": {
                    "ts": 132132132,
                    "msgId": "1"
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

            -- invalid req body - nubmer
            local _, err = ws:send_text([[{
                "uri": 1.1,
                "header": {
                    "ts": 132132132,
                    "msgId": "2"
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
        }
    }
--- response_body
status: 400
msgId: 1
message: 400 Invalid URI
status: 400
msgId: 2
message: 400 Invalid URI
--- timeout: 3s
