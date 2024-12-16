BEGIN {
    if ($ENV{TEST_NGINX_CHECK_LEAK}) {
        $SkipReason = "unavailable for the hup tests";

    } else {
        $ENV{TEST_NGINX_USE_HUP} = 1;
        undef $ENV{TEST_NGINX_USE_STAP};
    }
}

use t::APISIX 'no_plan';

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!defined $block->request) {
        $block->set_value("request", "GET /t");
    }
});

run_tests;

__DATA__

=== TEST 1: set route with prometheus ttl
--- yaml_config
plugin_attr:
    prometheus:
        default_buckets:
            - 15
            - 55
            - 105
            - 205
            - 505
        metrics:
            http_status:
                expire: 1
            http_latency:
                expire: 1
            bandwidth:
                expire: 1
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code = t('/apisix/admin/routes/metrics',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "public-api": {}
                    },
                    "uri": "/apisix/prometheus/metrics"
                }]]
                )
            if code >= 300 then
                ngx.status = code
                return
            end
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "prometheus": {}
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    },
                    "uri": "/hello1"
                }]]
                )
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end
            local code, body = t('/hello1',
                ngx.HTTP_GET,
                "",
                nil,
                nil
            )
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end
            ngx.sleep(2)
            local code, pass, body = t('/apisix/prometheus/metrics',
                ngx.HTTP_GET,
                "",
                nil,
                nil
            )

            local metrics_to_check = {"apisix_bandwidth", "http_latency", "http_status",}

            -- verify that above mentioned metrics are not in the metrics response
            for _, v in pairs(metrics_to_check) do
                local match, err = ngx.re.match(body, "\\b" .. v .. "\\b", "m")
                if match then
                    ngx.status = 500
                    ngx.say("error found " .. v .. " in metrics")
                    return
                end
            end

            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed
