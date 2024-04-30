use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_root_location();
no_shuffle();
log_level('info');

add_block_preprocessor(sub {
    my ($block) = @_;

my $user_yaml_config = <<_EOC_;
plugins:
  - error-page
  - serverless-post-function
_EOC_
    $block->set_value("extra_yaml_config", $user_yaml_config);

    if (!defined $block->request) {
        $block->set_value("request", "GET /t");
    }

    $block;
});

run_tests;

__DATA__

=== TEST 1: set global rule to enable plugin
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/global_rules/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "error-page": {}
                    }
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



=== TEST 2: set route with serverless-post-function plugin to inject failure
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "plugins": {
                        "serverless-post-function": {
                            "functions" : ["return function() if ngx.var.http_x_test_status ~= nil then;ngx.exit(tonumber(ngx.var.http_x_test_status));end;end"]
                        }
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    },
                    "uri": "/*"
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



=== TEST 3: test without creating plugin metadata shouldn't modify response
--- request
GET /hello
--- more_headers
X-Test-Status: 502
--- error_code: 502
--- response_headers
content-type: text/html
--- response_body_like
.*openresty.*
--- error_log
failed to read metadata for error-page



=== TEST 4: set plugin metadata with all default values
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            -- setting the metadata
            local code, body = t('/apisix/admin/plugin_metadata/error-page',
                ngx.HTTP_PUT,
                [[{"enable": true, "error_500": {}, "error_404": {}, "error_502": {}, "error_503": {}}]]
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



=== TEST 5: test apisix with internal error code 500
--- request
GET /hello
--- more_headers
X-Test-Status: 500
--- error_code: 500
--- response_headers
content-type: text/html
--- response_body_like
<center><h1>500 Internal Server Error</h1></center>
<hr><center>API7 Entreprise Edition</center>



=== TEST 6: test apisix with internal error code 502
--- request
GET /hello
--- more_headers
X-Test-Status: 502
--- error_code: 502
--- response_headers
content-type: text/html
--- response_body_like
<center><h1>502 Bad Gateway</h1></center>
<hr><center>API7 Entreprise Edition</center>



=== TEST 7: test apisix with internal error code 503
--- request
GET /hello
--- more_headers
X-Test-Status: 503
--- error_code: 503
--- response_headers
content-type: text/html
--- response_body_like
<center><h1>503 Service Unavailable</h1></center>
<hr><center>API7 Entreprise Edition</center>



=== TEST 8: test apisix with internal error code 404
--- request
GET /hello
--- more_headers
X-Test-Status: 404
--- error_code: 404
--- response_headers
content-type: text/html
--- response_body_like
<center><h1>404 Not Found</h1></center>
<hr><center>API7 Entreprise Edition</center>



=== TEST 9: error page not defined for code 405
--- request
GET /hello
--- more_headers
X-Test-Status: 405
--- error_code: 405
--- error_log
error page for error_405 not defined



=== TEST 10: set plugin metadata with error-page body not defined for 405
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            -- setting the metadata
            local code, body = t('/apisix/admin/plugin_metadata/error-page',
                ngx.HTTP_PUT,
                [[{"enable": true, "error_405": {}}]]
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



=== TEST 11: error page `body` not defined for code 405
--- request
GET /hello
--- more_headers
X-Test-Status: 405
--- error_code: 405
--- error_log
error page for error_405 not defined



=== TEST 12: set plugin metadata with error-page disabled
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            -- setting the metadata
            local code, body = t('/apisix/admin/plugin_metadata/error-page',
                ngx.HTTP_PUT,
                [[{"enable": false, "error_500": {}, "error_404": {}, "error_502": {}, "error_503": {}}]]
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



=== TEST 13: test `error-page.enable = false`
--- request
GET /hello
--- more_headers
X-Test-Status: 500
--- error_code: 500
--- response_headers
content-type: text/html
--- response_body_like
.*openresty.*
