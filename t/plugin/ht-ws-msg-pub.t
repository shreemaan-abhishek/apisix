use Cwd qw(cwd);
use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_root_location();

my $apisix_home = $ENV{APISIX_HOME} // cwd();

add_block_preprocessor(sub {
    my ($block) = @_;

    my $extra_yaml_config = $block->extra_yaml_config // <<_EOC_;
plugins:
    - ht-ws-msg-pub
    - serverless-pre-function
plugin_attr:
    ht-ws-msg-pub:
        enable_log: true
        heartbeat_interval: 1
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



=== TEST 2: connect websocket service
--- config
    location /t {
        content_by_lua_block {
            local core   = require("apisix.core")
            local ws_client = require "resty.websocket.client"
            local ws = ws_client:new()
            local ok, err = ws:connect("ws://127.0.0.1:1984/ht_ws")
            if not ok then
                ngx.log(ngx.ERR, "failed to connect: "..err)
            end

            local _, err = ws:send_ping([[{
                "msgId": "123",
                "ts": 1213343224
            }]])
            if err then
                ngx.log(ngx.ERR, "failed to send text: "..err)
                ngx.exit(444)
            end

            local raw_data, raw_type, err = ws:recv_frame()
            ngx.say("type: ", raw_type)
            if not raw_data then
                ngx.log(ngx.ERR, "failed to receive the frame: ", err)
                ngx.exit(444)
            end

            local data = core.json.decode(raw_data)
            if data then
                ngx.say("msgId: ", data.msgId)
            end

            ws:close()
        }
    }
--- response_body
type: pong
msgId: 123



=== TEST 3: send undecodable data (server skip loop, keep connection)
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

            local _, err = ws:send_text("none-json")
            if err then
                ngx.log(ngx.ERR, "failed to send text: "..err)
                ngx.exit(444)
            end

            ws:close()
        }
    }
--- ignore_response
--- error_log
failed to decode websocket frame, err: Expected value but found invalid token at character 1, req_data: none-json



=== TEST 4: setup route to mock push gateway
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t("/apisix/admin/routes/mock-ws", ngx.HTTP_PUT, {
                plugins = {
                    ["serverless-pre-function"] = {
                        phase = "access",
                        functions =  {
                            [[return function(conf, ctx)
                                local ws_server = require("resty.websocket.server")
                                local core = require("apisix.core");

                                local wb, err = ws_server:new()

                                while true do
                                    local raw_data, typ, err = wb:recv_frame()
                                    if wb.fatal then
                                        core.log.error("serverless function fatal failed to receive the frame: ", err)
                                        break
                                    end

                                    if not raw_data then
                                        core.log.error("serverless function failed to receive the frame: ", err)
                                    end

                                    local data = core.json.decode(raw_data)
                                    if typ == "ping" then
                                        core.log.info("receive ping message from plugin ht-ws-msg-pub, msgid: ", data.msgid)
                                        wb.send_pong(core.json.encode({
                                            msgid = data.msgid
                                        }))
                                    end
                                end
                                ngx.exit(0)
                            end]],
                        }
                    }
                },
                uri = "/mock-ws"
            })
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 5: set metadata for plugin ht-ws-msg-pub
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t("/apisix/admin/plugin_metadata/ht-ws-msg-pub", ngx.HTTP_PUT, {
                api7_push_gateway_addrs = {
                    "ws://127.0.0.1:1984/mock-ws"
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



=== TEST 6: test heartbeat
--- config
    location /t {
        content_by_lua_block {
        }
    }

--- ignore_response
--- timeout: 10s
--- wait: 3
--- error_log
receive ping message from plugin ht-ws-msg-pub



=== TEST 7: setup subroute for route ht_ws
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t("/apisix/admin/routes/sub", ngx.HTTP_PUT, [[
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
                "uri": "/cft/10004/*"
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



=== TEST 8: send websocket message to hit the subroute
--- config
    location /t {
        content_by_lua_block {
            local core   = require("apisix.core")
            local ws_client = require "resty.websocket.client"
            local ws = ws_client:new()
            local ok, err = ws:connect("ws://127.0.0.1:1984/ht_ws")
            if not ok then
                ngx.log(ngx.ERR, "failed to connect: "..err)
            end

            local _, err = ws:send_text([[{
                "uri":"/cft/10004/sub_put",
                "header": {
                    "ts": 132132132,
                    "msgId": "01321312",
                    "client-metadata": {}
                },
                "body":{
                    "topics":["hq_100001_129", "hq_100001_123"]
                }
            }]])

            if err then
                ngx.log(ngx.ERR, "failed to send text: "..err)
                ngx.exit(444)
            end

            ws:close()
        }
    }
--- ignore_response
--- timeout: 4s
--- wait: 3
--- error_log
hit the subroute: true
receive ping message from plugin ht-ws-msg-pub



=== TEST 9: send websocket message that miss the subroute
--- config
    location /t {
        content_by_lua_block {
            local core   = require("apisix.core")
            local ws_client = require "resty.websocket.client"
            local ws = ws_client:new()
            local ok, err = ws:connect("ws://127.0.0.1:1984/ht_ws")
            if not ok then
                ngx.log(ngx.ERR, "failed to connect: "..err)
            end

            local _, err = ws:send_text([[{
                "uri":"/cft/10003/sub_put",
                "header": {
                    "ts": 132132132,
                    "msgId": "01321312",
                    "client-metadata": {}
                },
                "body":{
                    "topics":["hq_100001_129", "hq_100001_123"]
                }
            }]])

            if err then
                ngx.log(ngx.ERR, "failed to send text: "..err)
                ngx.exit(444)
            end

            ws:close()
        }
    }
--- ignore_response
--- timeout: 3s
--- wait: 2
--- error_log
hit the subroute: false



=== TEST 10: setup subroute with header vars for route ht_ws
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t("/apisix/admin/routes/sub", ngx.HTTP_PUT, [=[
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
                "vars": [["http_market", "==", "sz"]],
                "uri": "/cft/10002/*"
            }
            ]=])
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 11: send websocket message that hit the subroute with header
--- config
    location /t {
        content_by_lua_block {
            local core   = require("apisix.core")
            local ws_client = require "resty.websocket.client"
            local ws = ws_client:new()
            local ok, err = ws:connect("ws://127.0.0.1:1984/ht_ws")
            if not ok then
                ngx.log(ngx.ERR, "failed to connect: "..err)
            end

            local _, err = ws:send_text([[{
                "uri":"/cft/10002/sub_put",
                "header": {
                    "ts": 132132132,
                    "msgId": "01321312",
                    "market": "sz"
                },
                "body":{
                    "topics":["hq_100001_129", "hq_100001_123"]
                }
            }]])

            if err then
                ngx.log(ngx.ERR, "failed to send text: "..err)
                ngx.exit(444)
            end

            ws:close()
        }
    }
--- ignore_response
--- timeout: 3s
--- wait: 2
--- error_log
hit the subroute: true



=== TEST 12: send websocket message that miss the subroute with header
--- config
    location /t {
        content_by_lua_block {
            local core   = require("apisix.core")
            local ws_client = require "resty.websocket.client"
            local ws = ws_client:new()
            local ok, err = ws:connect("ws://127.0.0.1:1984/ht_ws")
            if not ok then
                ngx.log(ngx.ERR, "failed to connect: "..err)
            end

            local _, err = ws:send_text([[{
                "uri":"/cft/10002/sub_put",
                "header": {
                    "ts": 132132132,
                    "msgId": "01321312",
                    "market": "sh"
                },
                "body":{
                    "topics":["hq_100001_129", "hq_100001_123"]
                }
            }]])

            if err then
                ngx.log(ngx.ERR, "failed to send text: "..err)
                ngx.exit(444)
            end

            ws:close()
        }
    }
--- ignore_response
--- timeout: 3s
--- wait: 2
--- error_log
hit the subroute: false



=== TEST 13: test ping/pong
--- config
    location /t {
        content_by_lua_block {
            local core   = require("apisix.core")
            local ws_client = require "resty.websocket.client"
            local ws = ws_client:new()
            local ok, err = ws:connect("ws://127.0.0.1:1984/ht_ws")
            if not ok then
                ngx.log(ngx.ERR, "failed to connect: "..err)
            end

            -- send ping
            local _, err = ws:send_text([[{
                "uri":"/api/ping",
                "header": {
                    "ts": 132132132,
                    "msgId": "01321312"
                }
            }]])

            if err then
                ngx.log(ngx.ERR, "failed to send text: "..err)
                ngx.exit(444)
            end

            -- receive pong
            local raw_data = ws:recv_frame()
            local msg = core.json.decode(raw_data)
            if data then
                ngx.say("uri: ", msg.uri)
                ngx.say("msgId: ", msg.header.msgId)
                ngx.say("ts: ", msg.header.ts)
            end

            ws:close()
        }
    }
--- ignore_response
--- timeout: 3s
--- wait: 2
--- response_body
uri: /api/pong
msgId: 01321312
ts: 132132132
