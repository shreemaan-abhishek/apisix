BEGIN {
    $ENV{REDIS_NODE_0} = "127.0.0.1:5000";
    $ENV{REDIS_NODE_1} = "127.0.0.1:5001";
}

use t::APISIX 'no_plan';

master_on();
workers(2);
no_shuffle();
check_accum_error_log();

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!$block->request) {
        $block->set_value("request", "GET /t");
    }
});

run_tests();

__DATA__

=== TEST 1: check schema - sync_interval should not be smaller than 0.1
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.limit-count.init")
            local conf = {
                count = 2,
                time_window = 1,
                policy = "redis",
                redis_host = "127.0.0.1",
                sync_interval = 0.09,
            }
            local ok, err = plugin.check_schema(conf)
            if not ok then
                ngx.say(err)
                return
            end
            ngx.say("passed")
        }
    }
--- response_body
sync_interval should not be smaller than 0.1



=== TEST 2: check schema - sync_interval should be smaller than time_window
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.limit-count.init")
            local conf = {
                count = 2,
                time_window = 1,
                policy = "redis",
                redis_host = "127.0.0.1",
                sync_interval = 1.1,
            }
            local ok, err = plugin.check_schema(conf)
            if not ok then
                ngx.say(err)
                return
            end
            ngx.say("passed")
        }
    }
--- response_body
sync_interval should be smaller than time_window



=== TEST 3: setup routes
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local apis = {
                  {
                      uri = "/apisix/admin/upstreams/localhost_1980",
                      body = [[{
                          "nodes": {
                              "127.0.0.1:1980": 1
                          },
                          "type": "roundrobin"
                      }]],
                  },
                  {
                      uri = "/apisix/admin/routes/mysleep",
                      body = [[{
                          "uri": "/mysleep",
                          "upstream_id": "localhost_1980"
                      }]],
                  },
                  {
                      uri = "/apisix/admin/routes/hello",
                      body = [[{
                          "uri": "/hello",
                          "plugins": {
                              "limit-count": {
                                  "count": 2,
                                  "time_window": 1,
                                  "key_type": "var",
                                  "key": "arg_key",
                                  "policy": "redis",
                                  "redis_host": "127.0.0.1",
                                  "sync_interval": 0.2
                              }
                          },
                          "upstream_id": "localhost_1980"
                      }]],
                  },
                  {
                      uri = "/apisix/admin/routes/hello1",
                      body = [[{
                          "uri": "/hello1",
                          "plugins": {
                              "limit-count": {
                                  "count": 2,
                                  "time_window": 1,
                                  "policy": "redis-cluster",
                                  "redis_cluster_nodes": [
                                      "$ENV://REDIS_NODE_0",
                                      "$ENV://REDIS_NODE_1"
                                  ],
                                  "redis_cluster_name": "redis-cluster-1",
                                  "sync_interval": 0.2
                              }
                          },
                          "upstream_id": "localhost_1980"
                      }]],
                  },
            }
            local code, body
            for _, api in ipairs(apis) do
                code, body = t(api.uri, ngx.HTTP_PUT, api.body)
                if code >= 300 then
                    ngx.status = code
                    ngx.say(body)
                    return
                end
            end
            ngx.say("passed")
        }
    }
--- response_body
passed



=== TEST 4: sanity - delayed sync to redis
--- pipelined_requests eval
["GET /hello", "GET /hello", "GET /hello", "GET /mysleep?seconds=1", "GET /hello", "GET /hello", "GET /hello"]
--- error_code eval
[200, 200, 503, 200, 200, 200, 503]
--- wait: 1
--- grep_error_log eval
qr{delayed sync to redis}
--- grep_error_log_out eval
qr/(delayed sync to redis\n){6}/



=== TEST 5: sanity - delayed sync to redis-cluster
--- pipelined_requests eval
["GET /hello1", "GET /hello1", "GET /hello1", "GET /mysleep?seconds=1", "GET /hello1", "GET /hello1", "GET /hello1"]
--- error_code eval
[200, 200, 503, 200, 200, 200, 503]
--- wait: 1
--- grep_error_log eval
qr{delayed sync to redis-cluster}
--- grep_error_log_out eval
qr/(delayed sync to redis-cluster\n){6}/



=== TEST 6: same plugin instance with `key_type:var` will use separate counter
--- pipelined_requests eval
["GET /hello?key=1", "GET /hello?key=1", "GET /hello?key=1",
"GET /hello?key=2", "GET /hello?key=2", "GET /hello?key=2"]
--- error_code eval
[200, 200, 503,
200, 200, 503]
--- wait: 1



=== TEST 7: multiple keys(DEDUPed) sync by same delayed_syncer
--- pipelined_requests eval
["GET /hello?key=1", "GET /hello?key=2", "GET /hello?key=1", "GET /hello?key=2"]
--- error_code eval
[200, 200, 200, 200]
--- wait: 1
--- grep_error_log chop
2 keys to be sync
--- grep_error_log_out eval
qr/(2 keys to be sync\n){1,}/



=== TEST 8: cleanup routes
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local uris = {
                "/apisix/admin/routes/hello",
                "/apisix/admin/routes/hello1",
                "/apisix/admin/routes/mysleep",
                "/apisix/admin/upstreams/localhost_1980",
            }
            local code, body
            for _, uri in ipairs(uris) do
                code, body = t(uri, ngx.HTTP_DELETE)
                if code >= 300 then
                    ngx.status = code
                    ngx.say(body)
                    return
                end
                ngx.sleep(0.1)
            end
            ngx.say("passed")
        }
    }
--- response_body
passed



=== TEST 9: setup routes
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local apis = {
                  {
                      uri = "/apisix/admin/upstreams/localhost_1980",
                      body = [[{
                          "nodes": {
                              "127.0.0.1:1980": 1
                          },
                          "type": "roundrobin"
                      }]],
                  },
                  {
                      uri = "/apisix/admin/routes/hello",
                      body = [[{
                          "uri": "/hello",
                          "plugins": {
                              "limit-count-advanced": {
                                  "count": 2,
                                  "time_window": 1,
                                  "key_type": "var",
                                  "key": "arg_key",
                                  "policy": "redis",
                                  "redis_host": "127.0.0.1",
                                  "window_type": "sliding",
                                  "sync_interval": 0.2
                              }
                          },
                          "upstream_id": "localhost_1980"
                      }]],
                  },
                  {
                      uri = "/apisix/admin/routes/hello1",
                      body = [[{
                          "uri": "/hello1",
                          "plugins": {
                              "limit-count-advanced": {
                                  "count": 2,
                                  "time_window": 1,
                                  "policy": "redis-cluster",
                                  "redis_cluster_nodes": [
                                      "$ENV://REDIS_NODE_0",
                                      "$ENV://REDIS_NODE_1"
                                  ],
                                  "redis_cluster_name": "redis-cluster-1",
                                  "window_type": "sliding",
                                  "sync_interval": 0.2
                              }
                          },
                          "upstream_id": "localhost_1980"
                      }]],
                  },
            }
            local code, body
            for _, api in ipairs(apis) do
                code, body = t(api.uri, ngx.HTTP_PUT, api.body)
                if code >= 300 then
                    ngx.status = code
                    ngx.say(body)
                    return
                end
            end
            ngx.say("passed")
        }
    }
--- response_body
passed



=== TEST 10: sanity - delayed sync to redis
--- pipelined_requests eval
["GET /hello", "GET /hello", "GET /hello"]
--- error_code eval
[200, 200, 503]
--- wait: 1
--- grep_error_log eval
qr{delayed sync to redis}
--- grep_error_log_out eval
qr/(delayed sync to redis\n){3}/



=== TEST 11: sanity - delayed sync to redis-cluster
--- pipelined_requests eval
["GET /hello1", "GET /hello1", "GET /hello1"]
--- error_code eval
[200, 200, 503]
--- wait: 1
--- grep_error_log eval
qr{delayed sync to redis-cluster}
--- grep_error_log_out eval
qr/(delayed sync to redis-cluster\n){3}/



=== TEST 12: create a route with limit-count plugin that enable delay sync
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin")
            local core = require("apisix.core")
            local code, body = t.test('/apisix/admin/routes/1ab5c95d',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/status",
                    "plugins": {
                      "limit-count": {
                          "count": 200,
                          "time_window": 60,
                          "key_type": "var",
                          "key": "remote_addr",
                          "show_limit_quota_header": true,
                          "policy": "redis",
                          "redis_host": "127.0.0.1",
                          "redis_port": 6379,
                          "sync_interval": 0.1
                      }
                    },
                    "upstream": {
                        "type": "roundrobin",
                        "nodes": {
                            "127.0.0.1:1980": 1
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 13: request at slow pace and check counter in redis after period of time
--- config
    location /t {
        content_by_lua_block {
            local json = require "t.toolkit.json"
            local http = require "resty.http"
            local uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/status"
            for i = 1, 5 do
                local httpc = http.new()
                local res, err = httpc:request_uri(uri)
                if not res then
                    ngx.say(err)
                    return
                end
                assert(tonumber(res.headers["X-RateLimit-Remaining"]) == 200 - i)
                ngx.sleep(0.5)
            end

            local redis = require "resty.redis"
            local red = redis:new()
            local ok, err = red:connect("127.0.0.1", 6379)
            if not ok then
                ngx.say("failed to connect redis: ", err)
                return
            end

            local res, err = red:keys("plugin-limit-countroute1ab5c95d*")
            if not res then
                ngx.say("failed to execute keys command to redis: ", err)
                return
            end

            if table.getn(res) == 0 then
                ngx.say("redis don't have the key")
                return
            end
            local count, err = red:get(res[1])
            if err then
                ngx.say("failed to get key from redis: ", err)
                return
            end
            ngx.say(count)
        }
    }
--- response_body
195
