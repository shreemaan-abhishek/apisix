use t::APISIX;

my $nginx_binary = $ENV{'TEST_NGINX_BINARY'} || 'nginx';
my $version = eval { `$nginx_binary -V 2>&1` };

if ($version !~ m/\/apisix-nginx-module/) {
    plan(skip_all => "apisix-nginx-module not installed");
} else {
    plan('no_plan');
}

repeat_each(1);
log_level('info');
no_root_location();
no_shuffle();

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!$block->http_config) {
        my $http_config = <<'_EOC_';

proxy_ssl_trusted_certificate ../../certs/mtls_ca.crt;
proxy_ssl_verify on;

server {
    listen 8777 ssl;
    ssl_certificate ../../certs/mtls_server.crt;
    ssl_certificate_key ../../certs/mtls_server.key;
    ssl_client_certificate ../../certs/mtls_ca.crt;
    ssl_verify_client on;

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

run_tests();

__DATA__

=== TEST 1: wrong ca cert
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin")
            local json = require("toolkit.json")
            local ssl_cert = t.read_file("t/certs/mtls_client.crt")
            local ssl_key = t.read_file("t/certs/mtls_client.key")
            local data = {
                upstream = {
                    scheme = "https",
                    type = "roundrobin",
                    nodes = {
                        ["127.0.0.1:8777"] = 1,
                    },
                    tls = {
                        client_cert = ssl_cert,
                        client_key = ssl_key,
                        verify = true,
                        ca_certs = {"wrong"}
                    }
                },
                uri = "/hello"
            }
            local code, body = t.test('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                json.encode(data)
            )

            if code >= 300 then
                ngx.status = code
                ngx.print(body)
                return
            end
            ngx.say("passed")
        }
    }
--- request
GET /t
--- error_code: 400
--- response_body
{"error_msg":"failed to parse cert: PEM_read_bio_X509_AUX() failed"}



=== TEST 2: set ssl.verify to true
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin")
            local json = require("toolkit.json")
            local ssl_cert = t.read_file("t/certs/mtls_client.crt")
            local ssl_key = t.read_file("t/certs/mtls_client.key")
            local data = {
                upstream = {
                    scheme = "https",
                    type = "roundrobin",
                    nodes = {
                        ["127.0.0.1:8777"] = 1,
                    },
                    tls = {
                        client_cert = ssl_cert,
                        client_key = ssl_key,
                        verify = true,
                    }
                },
                uri = "/hello"
            }
            local code, body = t.test('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                json.encode(data)
            )

            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end
            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 3: success to verify using admin.apisix.dev
--- request
GET /hello
--- more_headers
host: admin.apisix.dev
--- response_body
ok



=== TEST 4: failed to verify using invalid.apisix.dev
--- request
GET /hello
--- more_headers
host: invalid.apisix.dev
--- error_code: 502
--- error_log
upstream SSL certificate does not match "invalid.apisix.dev"



=== TEST 5: set ssl.verify to true and specify a invalid ca
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin")
            local json = require("toolkit.json")
            local ssl_cert = t.read_file("t/certs/mtls_client.crt")
            local ssl_key = t.read_file("t/certs/mtls_client.key")
            local invalid_ca = t.read_file("t/certs/apisix.crt")
            local data = {
                upstream = {
                    scheme = "https",
                    type = "roundrobin",
                    nodes = {
                        ["127.0.0.1:8777"] = 1,
                    },
                    tls = {
                        client_cert = ssl_cert,
                        client_key = ssl_key,
                        verify = true,
                        ca_certs = {invalid_ca},
                    }
                },
                uri = "/hello"
            }
            local code, body = t.test('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                json.encode(data)
            )

            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end
            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 6: cert verify failed
--- request
GET /hello
--- more_headers
host: admin.apisix.dev
--- error_code: 502
--- error_log
upstream SSL certificate verify error: (21:unable to verify the first certificate) while SSL handshaking to upstream



=== TEST 7: set ssl.verify to false and specify a invalid ca
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin")
            local json = require("toolkit.json")
            local ssl_cert = t.read_file("t/certs/mtls_client.crt")
            local ssl_key = t.read_file("t/certs/mtls_client.key")
            local invalid_ca = t.read_file("t/certs/apisix.crt")
            local data = {
                upstream = {
                    scheme = "https",
                    type = "roundrobin",
                    nodes = {
                        ["127.0.0.1:8777"] = 1,
                    },
                    tls = {
                        client_cert = ssl_cert,
                        client_key = ssl_key,
                        verify = false,
                        ca_certs = {invalid_ca},
                    }
                },
                uri = "/hello"
            }
            local code, body = t.test('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                json.encode(data)
            )

            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end
            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 8: ignore cert verify
--- request
GET /hello
--- more_headers
host: admin.apisix.dev
--- error_code: 200
--- response_body
ok



=== TEST 9: set ssl.verify to true and specify a ca
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin")
            local json = require("toolkit.json")
            local ssl_cert = t.read_file("t/certs/mtls_client.crt")
            local ssl_key = t.read_file("t/certs/mtls_client.key")
            local ca = t.read_file("t/certs/mtls_ca.crt")
            local data = {
                upstream = {
                    scheme = "https",
                    type = "roundrobin",
                    nodes = {
                        ["127.0.0.1:8777"] = 1,
                    },
                    tls = {
                        client_cert = ssl_cert,
                        client_key = ssl_key,
                        verify = true,
                        ca_certs = {ca},
                    }
                },
                uri = "/hello"
            }
            local code, body = t.test('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                json.encode(data)
            )

            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end
            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 10: cert verify success
--- request
GET /hello
--- more_headers
host: admin.apisix.dev
--- response_body
ok



=== TEST 11: two ca
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin")
            local json = require("toolkit.json")
            local ssl_cert = t.read_file("t/certs/mtls_client.crt")
            local ssl_key = t.read_file("t/certs/mtls_client.key")
            local ca = t.read_file("t/certs/mtls_ca.crt")
            local invalid_ca = t.read_file("t/certs/apisix.crt")
            local data = {
                upstream = {
                    scheme = "https",
                    type = "roundrobin",
                    nodes = {
                        ["127.0.0.1:8777"] = 1,
                    },
                    tls = {
                        client_cert = ssl_cert,
                        client_key = ssl_key,
                        verify = true,
                        ca_certs = {invalid_ca, ca},
                    }
                },
                uri = "/hello"
            }
            local code, body = t.test('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                json.encode(data)
            )

            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end
            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 12: success to verify using second ca
--- request
GET /hello
--- more_headers
host: admin.apisix.dev
--- response_body
ok
