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
        heartbeat_interval: 1
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

=== TEST 1: support for enabling log rotate
--- config
    location /t {
        content_by_lua_block {
            ngx.sleep(3)
            local has_split_log_file = false
            local lfs = require("lfs")
            for file_name in lfs.dir(ngx.config.prefix() .. "/logs/") do
                if string.match(file_name, "__ht_msg_sub.log$") then
                    has_split_log_file = true
                end
            end

            if not has_split_log_file then
                ngx.say("failed")
            else
                ngx.say("ok")
            end
        }
    }
--- timeout: 5
--- response_body
ok



=== TEST 2: setup route with plugin ht-ws-msg-pub
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



=== TEST 3: set metadata for plugin ht-ws-msg-pub
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



=== TEST 4: test subroute with vars and cache
--- config
    location /t {
        content_by_lua_block {
            local core   = require("apisix.core")
            local ws_client = require "resty.websocket.client"
            local t = require("lib.test_admin").test

            -- setup subroute with header vars(market == sz)
            t("/apisix/admin/routes/sub", ngx.HTTP_PUT, [=[
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
                "vars": [["http_market", "==", "sz"]],
                "uri": "/60150/ormp/subscribe/accountSubscribe"
            }
            ]=])

            ngx.sleep(0.1)

            local ws = ws_client:new()
            local ok, err = ws:connect("ws://127.0.0.1:1984/ht_ws")
            if not ok then
                ngx.log(ngx.ERR, "failed to connect: "..err)
            end

            -- send the same message with header market=sh, shall not match the subroute
            local _, err = ws:send_text([[{
                "uri":"/60150/ormp/subscribe/accountSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "1",
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

            -- receive the result of subscription
            local raw_data, raw_type, err = ws:recv_frame()
            ngx.log(ngx.INFO, "raw_data: ", raw_data)
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

            -- send the same message with header market=sz, shall match the subroute
            local _, err = ws:send_text([[{
                "uri":"/60150/ormp/subscribe/accountSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "2",
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

            -- receive the result of subscription
            local raw_data, raw_type, err = ws:recv_frame()
            ngx.log(ngx.INFO, "raw_data: ", raw_data)
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

            -- update the subroute vars
            t("/apisix/admin/routes/sub", ngx.HTTP_PUT, [=[
            {
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
                "labels": {
                    "superior_id": "ht_ws"
                },
                "vars": [["http_market", "==", "sh"]],
                "uri": "/60150/ormp/subscribe/accountSubscribe"
            }
            ]=])

            ngx.sleep(0.1)

            -- send the same message with header market=sh again, shall match the new subroute
            local _, err = ws:send_text([[{
                "uri":"/60150/ormp/subscribe/accountSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "3",
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

            -- receive the result of subscription
            local raw_data, raw_type, err = ws:recv_frame()
            ngx.log(ngx.INFO, "raw_data: ", raw_data)
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

            -- send the same message with header market=sz again, shall not match the new subroute
            local _, err = ws:send_text([[{
                "uri":"/60150/ormp/subscribe/accountSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "4",
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

            -- receive the result of subscription
            local raw_data, raw_type, err = ws:recv_frame()
            ngx.log(ngx.INFO, "raw_data: ", raw_data)
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
--- timeout: 3s
--- wait: 2
--- response_body
status: 404
msgId: 1
message: 404 Route Not Found
status: 200
msgId: 2
message: upstream success
status: 200
msgId: 3
message: upstream success
status: 404
msgId: 4
message: 404 Route Not Found
--- error_log
hit the subroute: false
hit the subroute: true
hit the subroute: true
hit the subroute: false



=== TEST 5: test subroute with plugin config and cache
--- config
    location /t {
        content_by_lua_block {
            local shell = require("resty.shell")
            local ws_client = require("resty.websocket.client")
            local core   = require("apisix.core")
            local t = require("lib.test_admin").test

            t('/apisix/admin/plugin_configs/1',
                ngx.HTTP_PUT,
                [[{
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
                    }
                }]]
            )

            -- update subroute with plugin_config_id
            local code, body = t("/apisix/admin/routes/sub", ngx.HTTP_PUT, [=[
            {
                "labels": {
                    "superior_id": "ht_ws"
                },
                "upstream": {
                    "nodes": [{
                        "host": "127.0.0.1",
                        "port": 1975,
                        "weight": 1
                    }],
                    "type": "roundrobin"
                },
                "plugin_config_id": "1",
                "uri": "/60150/ormp/subscribe/accountSubscribe"
            }
            ]=])
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)

            ngx.sleep(0.1)

            local ws = ws_client:new()
            local ok, err = ws:connect("ws://127.0.0.1:1984/ht_ws")
            if not ok then
                ngx.log(ngx.ERR, "failed to connect: "..err)
            end
            ws:set_timeout(1000)

            -- subscribe topic
            local _, err = ws:send_text([[{
                "uri":"/60150/ormp/subscribe/accountSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "1"
                },
                "body":{
                    "topics":["hq_100001_199", "hq_100001_193"]
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
            core.log.warn("subscribe response raw_data: ", raw_data)

            ngx.sleep(0.1)

            -- push msg to topic hq_100001_199
            local ok, stdout, stderr, reason, status = shell.run([[grpcurl -H 'topic: hq_100001_199' -H 'msgid: 199' -plaintext -d '{"body":"cTE5OQ=="}' 127.0.0.1:9110 pushserverpb.Push.Msg]], nil, 200)
            core.log.warn("push to topic hq_100001_199 ok: ", ok, " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)

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

            -- update plugin_config to sub_delete
            local code, body = t('/apisix/admin/plugin_configs/1',
                ngx.HTTP_PUT,
                [[{
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
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)

            ngx.sleep(0.1)

            -- cancel subscription because of plugin_config update
            local _, err = ws:send_text([[{
                "uri":"/60150/ormp/subscribe/accountSubscribe",
                "header": {
                    "ts": 132132132,
                    "msgId": "2"
                },
                "body":{
                    "topics":["hq_100001_199"]
                }
            }]])

            -- receive the result of canceling subscription
            local raw_data, raw_type, err = ws:recv_frame()
            if not raw_data then
                ngx.log(ngx.ERR, "failed to receive the frame: ", err)
                ngx.exit(444)
            end

            -- push msg to topic hq_100001_199
            local ok, stdout, stderr, reason, status = shell.run([[grpcurl -H 'topic: hq_100001_199' -H 'msgid: 199' -plaintext -d '{"body":"cTE5OQ=="}' 127.0.0.1:9110 pushserverpb.Push.Msg]], nil, 200)
            core.log.warn("push to topic hq_100001_199 ok: ", ok, " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)

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

            -- restart push gateway server
            local ok, stdout, stderr, reason, status = shell.run([[docker restart api7-push-gateway]], nil, 2000)
            core.log.warn("restart push gateway server, ok: ", ok, " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)

            -- wait for push gateway started
            local ok, stdout, stderr, reason, status = shell.run([[t/lib/wait_for.sh http://127.0.0.1:9110/list/topics 10]], nil, 10000)
            core.log.warn("wait for push gateway server, ok: ", ok, " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)

            -- wait for topics sync
            ngx.sleep(1.5)

            -- push msg to topic hq_100001_193
            local ok, stdout, stderr, reason, status = shell.run([[grpcurl -H 'topic: hq_100001_193' -H 'msgid: 193' -plaintext -d '{"body":"cTE5Mw=="}' 127.0.0.1:9110 pushserverpb.Push.Msg]], nil, 200)
            core.log.warn("push to topic hq_100001_193 ok: ", ok, " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)

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

            -- check the connections of push gateway
            local http = require "resty.http"
            local uri = "http://127.0.0.1:9110/list/workers"
            local httpc = http.new()
            httpc:set_timeout(1000)
            local res, err = httpc:request_uri(uri, {method = "GET", keepalive = false})
            if res then
                local msg = core.json.decode(res.body)
                ngx.say("workers: ", #msg.workers)
            end
            ngx.say("error: ", err)
        }
    }
--- response_body
passed
data:q199, topic:hq_100001_199
passed
failed to receive the frame
data:q193, topic:hq_100001_193
workers: 1
error: nil
--- timeout: 20s
--- error_log
from push gateway thread exit: failed to receive the first 2 bytes: closed
