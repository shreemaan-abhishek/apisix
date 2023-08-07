use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_root_location();

add_block_preprocessor(sub {
    my ($block) = @_;

    # setup default conf.yaml
    my $extra_yaml_config = $block->extra_yaml_config // <<_EOC_;
plugin_attr:
  soap:
    endpoint: http://127.0.0.1:15001
_EOC_

    $block->set_value("extra_yaml_config", $extra_yaml_config);

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
--- request
POST /getCountry
{"name": "Spain"}
--- more_headers
Content-Type: application/json
--- response_body
{"name": "Spain", "population": 46704314, "capital": "Madrid", "currency": "EUR"}