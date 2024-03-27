use t::APISIX 'no_plan';

log_level('warn');
repeat_each(1);
no_long_string();
no_root_location();
no_shuffle();

add_block_preprocessor(sub {
    my ($block) = @_;

    # setup default conf.yaml
    my $extra_yaml_config = $block->extra_yaml_config // '';
    $extra_yaml_config .= <<_EOC_;
plugins:
  - saml-auth                      # priority: 2598
_EOC_

    $block->set_value("extra_yaml_config", $extra_yaml_config);

    my $http_config = $block->http_config // '';
    $http_config .= <<_EOC_;
    lua_shared_dict saml_sessions 10m;
_EOC_

    $block->set_value("http_config", $http_config);

    if (!defined $block->request) {
        $block->set_value("request", "GET /t");
    }

    if ((!defined $block->error_log) && (!defined $block->no_error_log)) {
        $block->set_value("no_error_log", "[error]");
    }
});

run_tests;

__DATA__

=== TEST 1: Add route for sp1
--- config
    location /t {
        content_by_lua_block {
            local kc = require("lib.keycloak_saml")
            local core = require("apisix.core")

            local default_opts = kc.get_default_opts()
            local opts = core.table.deepcopy(default_opts)
            opts.sp_issuer = "sp"
            local t = require("lib.test_admin").test

            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                        "host" : "127.0.0.1",
                        "plugins": {
                            "saml-auth": ]] .. core.json.encode(opts) .. [[
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
--- response_body
passed



=== TEST 2: login and logout ok
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.http"
            local httpc = http.new()
            local kc = require "lib.keycloak_saml"

            local path = "/uri"
            local uri = "http://127.0.0.1:" .. ngx.var.server_port
            local username = "test"
            local password = "test"

            local res, err, saml_cookie, keycloak_cookie = kc.login_keycloak(uri .. path, username, password)
            if err or res.headers['Location'] ~= path then
                ngx.log(ngx.ERR, err)
                ngx.exit(500)
            end
            res, err = httpc:request_uri(uri .. res.headers['Location'], {
                method = "GET",
                headers = {
                    ["Cookie"] = saml_cookie
                }
            })
            assert(res.status == 200)
            ngx.say(res.body)

            res, err = kc.logout_keycloak(uri .. "/logout", saml_cookie, keycloak_cookie)
            if err or res.headers['Location'] ~= "/logout_ok" then
                ngx.log(ngx.ERR, err)
                ngx.exit(500)
            end
        }
    }
--- response_body_like
uri: /uri
cookie: .*
host: 127.0.0.1:1984
user-agent: .*
x-real-ip: 127.0.0.1



=== TEST 3: Add route for sp2
--- config
    location /t {
        content_by_lua_block {
            local kc = require("lib.keycloak_saml")
            local core = require("apisix.core")

            local default_opts = kc.get_default_opts()
            local opts = core.table.deepcopy(default_opts)
            opts.sp_issuer = "sp2"
            local t = require("lib.test_admin").test

            local code, body = t('/apisix/admin/routes/2',
                 ngx.HTTP_PUT,
                 [[{
                        "host" : "127.0.0.2",
                        "plugins": {
                            "saml-auth": ]] .. core.json.encode(opts) .. [[
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
--- response_body
passed



=== TEST 4: login sp1 and sp2, then do single logout
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.http"
            local httpc = http.new()
            local kc = require "lib.keycloak_saml"

            local path = "/uri"

            -- login to sp1
            local uri = "http://127.0.0.1:" .. ngx.var.server_port
            local username = "test"
            local password = "test"

            local res, err, saml_cookie, keycloak_cookie = kc.login_keycloak(uri .. path, username, password)
            if err or res.headers['Location'] ~= path then
                ngx.log(ngx.ERR, err)
                ngx.exit(500)
            end
            res, err = httpc:request_uri(uri .. res.headers['Location'], {
                method = "GET",
                headers = {
                    ["Cookie"] = saml_cookie
                }
            })
            assert(res.status == 200)

            -- login to sp2, which would skip login at keycloak side
            local uri2 = "http://127.0.0.2:" .. ngx.var.server_port

            local res, err, saml_cookie2 = kc.login_keycloak_for_second_sp(uri2 .. path, keycloak_cookie)
            if err or res.headers['Location'] ~= path then
                ngx.log(ngx.ERR, err)
                ngx.exit(500)
            end
            res, err = httpc:request_uri(uri2 .. res.headers['Location'], {
                method = "GET",
                headers = {
                    ["Cookie"] = saml_cookie2
                }
            })
            assert(res.status == 200)

            -- SLO (single logout)
            res, err = kc.single_logout(uri .. "/logout", saml_cookie, saml_cookie2, keycloak_cookie)
            if err or res.headers['Location'] ~= "/logout_ok" then
                ngx.log(ngx.ERR, err)
                ngx.exit(500)
            end

            -- login to sp2, which would do normal login process at keycloak side
            local res, err, saml_cookie2, keycloak_cookie = kc.login_keycloak(uri2 .. path, username, password)
            if err or res.headers['Location'] ~= path then
                ngx.log(ngx.ERR, err)
                ngx.exit(500)
            end
            res, err = httpc:request_uri(uri .. res.headers['Location'], {
                method = "GET",
                headers = {
                    ["Cookie"] = saml_cookie2
                }
            })
            assert(res.status == 200)

            -- logout sp2
            res, err = kc.logout_keycloak(uri2 .. "/logout", saml_cookie2, keycloak_cookie)
            if err or res.headers['Location'] ~= "/logout_ok" then
                ngx.log(ngx.ERR, err)
                ngx.exit(500)
            end
        }
    }



=== TEST 5: Add route for sp1 with wrong login_callback_uri
--- config
    location /t {
        content_by_lua_block {
            local kc = require("lib.keycloak_saml")
            local core = require("apisix.core")

            local default_opts = kc.get_default_opts()
            local opts = core.table.deepcopy(default_opts)
            opts.sp_issuer = "sp"
            opts.login_callback_uri = "/wrong_url"
            local t = require("lib.test_admin").test

            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                        "host" : "127.0.0.1",
                        "plugins": {
                            "saml-auth": ]] .. core.json.encode(opts) .. [[
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
--- response_body
passed



=== TEST 6: login failed
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.http"
            local httpc = http.new()
            local kc = require "lib.keycloak_saml"

            local path = "/uri"
            local uri = "http://127.0.0.1:" .. ngx.var.server_port
            local username = "test"
            local password = "test"

            local res = kc.login_keycloak(uri .. path, username, password)
            assert(res == nil)
        }
    }
