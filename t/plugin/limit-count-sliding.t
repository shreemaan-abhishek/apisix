use t::APISIX 'no_plan';

no_long_string();
no_shuffle();
no_root_location();

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!$block->request) {
        $block->set_value("request", "GET /t");
    }

    if (!$block->error_log && !$block->no_error_log) {
        $block->set_value("no_error_log", "[error]\n[alert]");
    }
});

run_tests;

__DATA__

=== TEST 1: set route(id: 1)
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                        "methods": ["GET"],
                        "plugins": {
                            "limit-count-advanced": {
                                "count": 2,
                                "time_window": 5,
                                "rejected_code": 503,
                                "key": "remote_addr",
                                "window_type": "sliding"
                            }
                        },
                        "upstream": {
                            "nodes": {
                                "127.0.0.1:1980": 1
                            },
                            "type": "roundrobin"
                        },
                        "uri": "/hello"
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



=== TEST 2: up the limit
--- pipelined_requests eval
["GET /hello", "GET /hello", "GET /hello"]
--- error_code eval
[200, 200, 503]



=== TEST 3: headers rounded off
# in this test we extract the rate limit header values then extract the decimal part
# to check if the decimal part is longer than 2
--- config
    location /t {
        content_by_lua_block {
            local http = require("resty.http")
            local core = require("apisix.core")

            local uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/hello"
            local opt = {method = "GET"}
            local httpc = http.new()

            local headers_to_check = {"X-RateLimit-Remaining", "X-RateLimit-Reset"}
            for i = 1, 5, 1 do
                local res = httpc:request_uri(uri, opt)
                local headers = res.headers

                local m, err = ngx.re.match(headers["X-RateLimit-Remaining"], "\\d(.*)")
                if not m then
                    ngx.status = 500
                    ngx.say("error: ", err)
                    return
                end

                local value = m[1]
                if #value > 0 then
                    ngx.status = 500
                    ngx.say("remaining should be an integer but found float")
                    return
                end

                local m, err = ngx.re.match(headers["X-RateLimit-Reset"], "\\d\\.?(.*)")
                if not m then
                    ngx.status = 500
                    ngx.say("error: ", err)
                    return
                end

                local value = m[1]
                if #value > 2 then
                    ngx.status = 500
                    ngx.say("x-ratelimit-recet decimal value has more than 2 digits")
                    return
                end

                if res.status == 200 then
                    ngx.sleep(1)
                else
                    ngx.sleep(1.5)
                end
            end
            ngx.say("passed")
        }
    }
--- request
GET /t
--- timeout: 10
--- error_code: 200
--- response_body
passed
