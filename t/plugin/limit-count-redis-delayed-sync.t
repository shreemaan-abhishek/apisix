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
