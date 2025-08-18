use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_root_location();

add_block_preprocessor(sub {
    my ($block) = @_;

    # setup default conf.yaml
    if (!$block->extra_yaml_config) {
        my $extra_yaml_config = $block->extra_yaml_config // <<_EOC_;
plugin_attr:
  soap:
    endpoint: http://127.0.0.1:15001
_EOC_

        $block->set_value("extra_yaml_config", $extra_yaml_config);
    }

    if (!$block->request) {
        $block->set_value("request", "GET /t");
    }

    if ((!defined $block->error_log) && (!defined $block->no_error_log)) {
        $block->set_value("no_error_log", "[error]");
    }
});

run_tests;

__DATA__

=== TEST 1: sanity
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                        "methods": ["POST"],
                        "plugins": {
                            "soap": {
                                "wsdl_url": "http://soap-server:8080/ws/countries.wsdl"
                            }
                        },
                        "uri": "/getCountry"
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



=== test 2: getCountry
--- config
    location /t {
        content_by_lua_block {
            local json = require("toolkit.json")
            local t = require("lib.test_admin").test

            local code, message, res = t('/getCountry',
                ngx.HTTP_POST,
                [[{"name": "Spain"}]],
                nil,
                {
                    ["Content-Type"] = "application/json"
                }
            )

            if code >= 300 then
                ngx.status = code
                ngx.say(message)
                return
            end

            res = json.decode(res)
            ngx.say(json.encode(res))
        }
    }
--- response_body
{"capital":"Madrid","currency":"EUR","name":"Spain","population":46704314}



=== TEST 3: check schema
--- config
    location /t {
        content_by_lua_block {
            local test_cases = {
                {wsdl_url = "http://127.0.0.1:8080"},
                {},
                {wsdl_url = 3233},
                {wsdl_url = "127.0.0.1:8080"},
                {wsdl_url = "http://soap-server:8080"}
            }
            local plugin = require("apisix.plugins.soap")
            for _, case in ipairs(test_cases) do
                local ok, err = plugin.check_schema(case)
                ngx.say(ok and "done" or err)
            end
        }
    }
--- response_body
done
property "wsdl_url" is required
property "wsdl_url" validation failed: wrong type: expected string, got number
property "wsdl_url" validation failed: failed to match pattern "^[^\\/]+:\\/\\/([\\da-zA-Z.-]+|\\[[\\da-fA-F:]+\\])(:\\d+)?" with "127.0.0.1:8080"
done



=== TEST 4: wrong endpoint
--- extra_yaml_config
plugin_attr:
  soap:
    endpoint: http://127.0.0.1:11111
--- request
POST /getCountry
{"name": "Spain"}
--- more_headers
Content-Type: application/json
--- error_code: 503
--- error_log
failed to process soap request, err: connection refused



=== TEST 5: wrong wsdl addr
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                        "methods": ["POST"],
                        "plugins": {
                            "soap": {
                                "wsdl_url": "http://soap-server:4444/ws/countries.wsdl"
                            }
                        },
                        "uri": "/getCountry"
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



=== TEST 6: hit - wrong wsdl
--- request
POST /getCountry
{"name": "Spain"}
--- more_headers
Content-Type: application/json
--- error_code: 500



=== TEST 7: wsdl not exits
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                        "methods": ["POST"],
                        "plugins": {
                            "soap": {
                                "wsdl_url": "http://soap-server:8080/ws/tt.wsdl"
                            }
                        },
                        "uri": "/getCountry"
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



=== TEST 8: hit - wsdl not exits
--- request
POST /getCountry
{"name": "Spain"}
--- more_headers
Content-Type: application/json
--- error_code: 500
--- response_body_like eval
qr/405 Client Error:  for url:/



=== TEST 9: normal routes
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                        "methods": ["POST"],
                        "plugins": {
                            "soap": {
                                "wsdl_url": "http://soap-server:8080/ws/countries.wsdl"
                            }
                        },
                        "uris": [
                            "/getCountry",
                            "/deleteCountry",
                            "/getAllCountries"
                        ]
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



=== TEST 10: deleteCountry: normal
--- config
    location /t {
        content_by_lua_block {
            local json = require("toolkit.json")
            local t = require("lib.test_admin").test

            local code, message, res = t('/deleteCountry',
                ngx.HTTP_POST,
                [[{"name": "Spain"}]],
                nil,
                {
                    ["Content-Type"] = "application/json"
                }
            )

            if code >= 300 then
                ngx.status = code
                ngx.say(message)
                return
            end

            res = json.decode(res)
            ngx.print(json.encode(res))
        }
    }
--- response_body chomp
{"code":200,"message":"ok"}



=== TEST 11: deleteCountry: country not exits, soap fault
--- config
    location /t {
        content_by_lua_block {
            local json = require("toolkit.json")
            local t = require("lib.test_admin").test

            local code, res = t('/deleteCountry',
                ngx.HTTP_POST,
                [[{"name": "hhhh"}]],
                nil,
                {
                    ["Content-Type"] = "application/json"
                }
            )

            res = json.decode(res)
            ngx.status = code
            ngx.print(json.encode(res))
        }
    }
--- error_code: 502
--- response_body chomp
{"code":"SOAP-ENV:Client","message":"Country not found"}



=== TEST 12: getAllCountries, empty json
--- config
    location /t {
        content_by_lua_block {
            local json = require("toolkit.json")
            local t = require("lib.test_admin").test

            local code, message, res = t('/getAllCountries',
                ngx.HTTP_POST,
                [[{}]],
                nil,
                {
                    ["Content-Type"] = "application/json"
                }
            )

            res = json.decode(res)
            ngx.status = code
            ngx.print(json.encode(res))
        }
    }
--- error_code: 200
--- response_body chomp
[{"capital":"Warsaw","currency":"PLN","name":"Poland","population":38186860},{"capital":"London","currency":"GBP","name":"United Kingdom","population":63705000}]



=== TEST 13: getAllCountries, empty param
--- request
POST /getAllCountries
''
--- more_headers
Content-Type: application/json
--- error_code: 500
--- response_body_like eval
--- response_body_chomp
{"py/reduce": [{"py/type": "werkzeug.exceptions.BadRequest"}, {"py/tuple": []}, {"response": null}]}
