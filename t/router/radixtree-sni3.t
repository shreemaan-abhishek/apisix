use t::APISIX 'no_plan';

log_level('debug');
no_root_location();

BEGIN {
    $ENV{TEST_NGINX_HTML_DIR} ||= html_dir();
}

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!$block->request) {
        $block->set_value("request", "GET /t");
    }

});


run_tests;

__DATA__

=== TEST 1: set sni with trailing period
--- config
location /t {
    content_by_lua_block {
        local core = require("apisix.core")
        local t = require("lib.test_admin")

        local ssl_cert = t.read_file("t/certs/test2.crt")
        local ssl_key =  t.read_file("t/certs/test2.key")
        local data = {cert = ssl_cert, key = ssl_key, sni = "*.test.com"}

        local code, body = t.test('/apisix/admin/ssls/1',
            ngx.HTTP_PUT,
            core.json.encode(data)
        )

        ngx.status = code
        ngx.say(body)
    }
}
--- request
GET /t
--- response_body
passed
--- error_code: 201



=== TEST 2: match against sni with no trailing period
--- config
listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;

location /t {
    content_by_lua_block {
        do
            local sock = ngx.socket.tcp()

            sock:settimeout(2000)

            local ok, err = sock:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            local sess, err = sock:sslhandshake(nil, "a.test.com.", false)
            if not sess then
                ngx.say("failed to do SSL handshake: ", err)
                return
            end
            ngx.say("ssl handshake: ", sess ~= nil)
        end  -- do
        -- collectgarbage()
    }
}
--- request
GET /t
--- response_body
ssl handshake: true



=== TEST 3: set snis with trailing period
--- config
location /t {
    content_by_lua_block {
        local core = require("apisix.core")
        local t = require("lib.test_admin")

        local ssl_cert = t.read_file("t/certs/test2.crt")
        local ssl_key =  t.read_file("t/certs/test2.key")
        local data = {cert = ssl_cert, key = ssl_key, snis = {"test2.com", "a.com"}}

        local code, body = t.test('/apisix/admin/ssls/1',
            ngx.HTTP_PUT,
            core.json.encode(data)
        )

        ngx.status = code
        ngx.say(body)
    }
}
--- request
GET /t
--- response_body
passed



=== TEST 4: match agains sni with no trailing period
--- config
listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;

location /t {
    content_by_lua_block {
        do
            local sock = ngx.socket.tcp()

            sock:settimeout(2000)

            local ok, err = sock:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            local sess, err = sock:sslhandshake(nil, "test2.com.", false)
            if not sess then
                ngx.say("failed to do SSL handshake: ", err)
                return
            end
            ngx.say("ssl handshake: ", sess ~= nil)
        end  -- do
        -- collectgarbage()
    }
}
--- request
GET /t
--- response_body
ssl handshake: true
