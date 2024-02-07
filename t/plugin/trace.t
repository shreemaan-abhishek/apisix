use t::APISIX 'no_plan';

repeat_each(1);
log_level('info');
worker_connections(256);
no_root_location();
no_shuffle();

add_block_preprocessor(sub {
    my ($block) = @_;

my $user_yaml_config = <<_EOC_;
plugins:
  - trace
  - serverless-post-function
_EOC_
    $block->set_value("extra_yaml_config", $user_yaml_config);

    if ((!defined $block->error_log) && (!defined $block->no_error_log)) {
        $block->set_value("no_error_log", "[error]");
    }

    if (!defined $block->request) {
        $block->set_value("request", "GET /t");
    }

});

run_tests();

__DATA__

=== TEST 1: create route
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/hello",
                    "plugins": {
                        "serverless-post-function": {
                            "phase": "log",
                            "functions": [
                                "return function () local json = require(\"apisix.core.json\")  ngx.log(ngx.INFO, \" Stable encode: \", json.stably_encode(ngx.ctx.timespan)); end"
                            ]
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
                ngx.say(body)
                return
            end
            ngx.say("done")
        }
    }
--- response_body
done



=== TEST 2: access
--- request
GET /hello
--- error_log eval
qr/Stable encode: {\"http_access_phase":(\d{1,2}\.\d+|0),\"match_route\":(\d{1,2}\.\d+|0)}/



=== TEST 3: test trace plugin actual log
--- request
GET /hello
--- error_log eval
trace:



=== TEST 4: remove plugin and send request after plugin reload
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local http = require("resty.http")

            local conf, err = io.open("t/servroot/conf/config.yaml", "w+")
            if not conf then
                ngx.status = 500
                ngx.say("Failed test: failed to open config file")
                return
            end

            -- yaml config to remove trace plugin
            local config = "deployment:\n  role: traditional\n  role_traditional:\n    config_provider: etcd\n  admin:\n    admin_key: null\napisix:\n  node_listen: 1984\n  proxy_mode: http&stream\n  stream_proxy:\n    tcp:\n      - 9100\n  enable_resolv_search_opt: false\nplugins:\n  - serverless-post-function\n"
            conf:write(config)

            -- reload plugins
            local code, _, org_body = t('/apisix/admin/plugins/reload', ngx.HTTP_PUT)
            if code >= 300 then
                ngx.status = code
                ngx.say(message)
                return
            end

            local uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/hello"
            local httpc = http.new()
            local res, err = httpc:request_uri(uri)
        }
    }
--- error_log
Stable encode: null
--- no_error_log
trace:
