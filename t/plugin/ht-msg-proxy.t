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



=== TEST 2: setup subroute for subscribe topic
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t("/apisix/admin/routes/11", ngx.HTTP_PUT, [[
            {
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



=== TEST 3: setup subroute for proxy
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



=== TEST 4: set metadata for plugin ht-ws-msg-pub
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



=== TEST 5: hit the proxy route by http - upstream unavailable
--- request
GET /60101/ormp/query
--- more_headers
wanted_code: -1
--- response_body_like eval
["\"msgId\":", "\"message\":\"failed to request upstream\""]
--- timeout: 3s
--- error_code: 502
--- error_log
failed to request upstream, resp: null, error: timeout



=== TEST 6: hit the proxy route by http - upstream response error
--- request
GET /60101/ormp/query
--- more_headers
wanted_code: failed
--- response_body_like eval
["\"message\":\"wanted code: failed\"", "\"code\":\"failed\""]
--- error_log_like eval
qr/failed to request upstream, resp: .*, error: nil/
--- ignore_error_log



=== TEST 7: hit the proxy route by http - upstream response ignored error
--- request
POST /60150/ormp/subscribe/accountSubscribe
{"topics":["hq_100001_179", "hq_100001_173"]}
--- more_headers
wanted_code: 11
--- response_body_like eval
["\"message\":\"wanted code: 11\""]
--- error_log
building sid topic relation
--- ignore_error_log



=== TEST 8: hit the proxy route by http - normal
--- request
GET /60101/ormp/query
--- response_body_like eval
["\"message\":\"upstream success\""]
--- no_error_log
building sid topic relation



=== TEST 9: subscribe topic by http
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, _, resp_data = t("/60150/ormp/subscribe/accountSubscribe", ngx.HTTP_POST, {
                topics = {
                    "hq_100001_179", "hq_100001_173"
                },
            })
            if code >= 300 then
                ngx.status = code
            end
            if string.find(resp_data, 'upstream success') ~= -1 then
                ngx.say("upstream success")
            else
                ngx.say("upstream failed")
            end

            ngx.sleep(1)

            local path = ngx.config.prefix() .. "/logs/ht_msg_sub.log"
            local fd, err = io.open(path, 'r')
            if not fd then
                core.log.error("failed to open file: file.log, error info: ", err)
                return
            end
            local msg = fd:read("*a")
            local index = string.find(msg, "[API7 Gateway] Subscribe Topics", 1, true)
            if index then
                ngx.say("has sub log")
            else
                ngx.say("no sub log")
            end
        }
    }
--- response_body
upstream success
no sub log
--- error_log
building sid topic relation



=== TEST 10: subscribe topic by websocket
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

            -- proxy query
            local _, err = ws:send_text([[{
                "uri":"/60101/ormp/query",
                "header": {
                    "ts": 132132132,
                    "msgId": "11",
                    "client-metadata": {}
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

            ngx.sleep(1)

            local path = ngx.config.prefix() .. "/logs/ht_msg_sub.log"
            local fd, err = io.open(path, 'r')
            if not fd then
                core.log.error("failed to open file: file.log, error info: ", err)
                return
            end
            local msg = fd:read("*a")
            local index = string.find(msg, "[API7 Gateway] Subscribe Topics", 1, true)
            if index then
                ngx.say("has sub log")
            else
                ngx.say("no sub log")
            end

            ws:close()
        }
    }
--- response_body
status: 200
msgId: 11
message: upstream success
has sub log
--- timeout: 3s
--- no_error_log
building sid topic relation



=== TEST 11: test proxy by websocket
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

            -- proxy query
            local _, err = ws:send_text([[{
                "uri":"/60101/ormp/query",
                "header": {
                    "ts": 132132132,
                    "msgId": "11",
                    "client-metadata": {}
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

            -- proxy query - upstream response error
            local _, err = ws:send_text([[{
                "uri":"/60101/ormp/query",
                "header": {
                    "ts": 132132132,
                    "msgId": "22",
                    "wanted_code": "failed"
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

            -- proxy query - upstream unavailable
            local _, err = ws:send_text([[{
                "uri":"/60101/ormp/query",
                "header": {
                    "ts": 132132132,
                    "msgId": "33",
                    "wanted_code": "-1"
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
message: upstream success
status: 200
msgId: 22
message: wanted code: failed
status: 502
msgId: 33
message: failed to request upstream
--- timeout: 3s
--- wait: 2
--- no_error_log
building sid topic relation



=== TEST 12: send invalid data (response 400)
--- config
    location /t {
        lua_check_client_abort on;
        content_by_lua_block {
            local core   = require("apisix.core")
            local ws_client = require "resty.websocket.client"
            local ws = ws_client:new()
            local ok, err = ws:connect("ws://127.0.0.1:1984/ht_ws")
            if not ok then
                ngx.log(ngx.ERR, "failed to connect: "..err)
            end

            local _, err = ws:send_text("{}")
            if err then
                ngx.log(ngx.ERR, "failed to send text: "..err)
                ngx.exit(444)
            end

            -- receive response
            local raw_data = ws:recv_frame()
            local msg = core.json.decode(raw_data)
            if msg then
                ngx.say("status: ", msg.status)
                ngx.say("code: ", 4001)
                ngx.say("message: ", "400 Invalid URI")
            end

            ws:close()
        }
    }
--- response_body
status: 400
code: 4001
message: 400 Invalid URI



=== TEST 13: test with decoder encode error - http
--- request
POST /60101/ormp/query
{"wanted_encode_error": "failed"}
--- error_code: 502
--- response_body_like eval
["\"message\":\"failed to request upstream\"", "\"code\":\"5022\""]
--- error_log
failed to encode req data: failed



=== TEST 14: test with decoder decode error - http
--- request
POST /60101/ormp/query
{"wanted_decode_error": "failed"}
--- error_code: 502
--- response_body_like eval
["\"message\":\"failed to request upstream\""]
--- error_log
failed to decode body: failed



=== TEST 15: test with decoder error - websocket
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

            -- test encode error
            local _, err = ws:send_text([[{
                "uri":"/60101/ormp/query",
                "header": {
                    "ts": 132132132,
                    "msgId": "11"
                },
                "body": {
                    "wanted_encode_error": "failed"
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
                ngx.say("message: ", data.body.message)
            end

            -- test decode error
            local _, err = ws:send_text([[{
                "uri":"/60101/ormp/query",
                "header": {
                    "ts": 132132132,
                    "msgId": "22"
                },
                "body": {
                    "wanted_decode_error": "failed"
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
                ngx.say("message: ", data.body.message)
            end

            ws:close()
        }
    }
--- response_body
status: 502
message: failed to request upstream
status: 502
message: failed to request upstream
--- timeout: 3s
--- wait: 2
--- error_log
failed to encode req data: failed
failed to decode body: failed
