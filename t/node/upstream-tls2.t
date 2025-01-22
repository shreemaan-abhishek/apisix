use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_root_location();
log_level("info");

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!$block->http_config) {
        my $http_config = <<'_EOC_';

proxy_ssl_trusted_certificate ../../certs/mtls_ca.crt;
proxy_ssl_verify on;

server {
    listen 8767 ssl;
    ssl_certificate ../../certs/mtls_server.crt;
    ssl_certificate_key ../../certs/mtls_server.key;
    ssl_client_certificate ../../certs/mtls_ca.crt;

    location /hello {
        return 200 'ok\n';
    }
}

_EOC_
        $block->set_value("http_config", $http_config);
    }

    if (!$block->request) {
        $block->set_value("request", "GET /t");
    }

});

run_tests;

__DATA__

=== TEST 1: set tls.verify to true
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "methods": ["GET"],
                    "upstream": {
                        "scheme": "https",
                        "type": "roundrobin",
                        "nodes": {
                            "127.0.0.1:8767": 1
                        },
                        "tls": {
                            "verify": true
                        }
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
--- request
GET /t
--- response_body
passed



=== TEST 2: success to verify using admin.apisix.dev
--- request
GET /hello
--- more_headers
host: admin.apisix.dev
--- response_body
ok



=== TEST 3: failed to verify using invalid.apisix.dev
--- request
GET /hello
--- more_headers
host: invalid.apisix.dev
--- error_code: 502
--- error_log
upstream SSL certificate does not match "invalid.apisix.dev"



=== TEST 4: set tls.verify to false
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "methods": ["GET"],
                    "upstream": {
                        "scheme": "https",
                        "type": "roundrobin",
                        "nodes": {
                            "127.0.0.1:8767": 1
                        },
                        "tls": {
                            "verify": false
                        }
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
--- request
GET /t
--- response_body
passed



=== TEST 5: success to verify using admin.apisix.dev
--- request
GET /hello
--- more_headers
host: admin.apisix.dev
--- response_body
ok



=== TEST 6: success to verify using invalid.apisix.dev
--- request
GET /hello
--- more_headers
host: invalid.apisix.dev
--- error_code: 200
--- response_body
ok
