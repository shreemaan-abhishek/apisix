use t::APISIX 'no_plan';

worker_connections(1024);
repeat_each(1);
no_long_string();
no_root_location();

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!$block->request) {
        $block->set_value("request", "GET /t");
    }
});

run_tests;

__DATA__

=== TEST 1: enable request-id plugin
--- yaml_config
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                        "plugins": {
                            "request-id": {
                                "header_name": "X-Request-Id"
                            }
                        },
                        "upstream": {
                            "nodes": {
                                "127.0.0.1:1999": 1
                            },
                            "type": "roundrobin"
                        },
                        "uri": "/opentracing"
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



=== TEST 2: check request-id
--- request
GET /opentracing
--- more_headers
X-Request-Id: abctesting
--- grep_error_log eval
qr/request_id: "abctesting"/
--- grep_error_log_out
request_id: "abctesting"
request_id: "abctesting"
request_id: "abctesting"
request_id: "abctesting"
--- error_code: 502
