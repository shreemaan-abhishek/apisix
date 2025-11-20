use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_root_location();


add_block_preprocessor(sub {
    my ($block) = @_;

    if (!defined $block->request) {
        $block->set_value("request", "GET /t");
    }

    my $http_config = $block->http_config // <<_EOC_;
    server {
        listen 1970;
        client_max_body_size 10m; 
        location /large_body {
            content_by_lua_block {
                ngx.req.read_body()
                local data = ngx.req.get_body_data()
                local file = ngx.req.get_body_file()

                local body_size = 0

                if data then
                    body_size = #data
                elseif file then
                    local f = io.open(file, "rb")
                    if f then
                        local size = f:seek("end")
                        f:close()
                        body_size = size
                    end
                else
                    body_size = 0
                end

                ngx.log(ngx.INFO, "body_size >= 2MB: ", body_size >= 2 * 1024 * 1024)
            }
        }
    }
_EOC_

    $block->set_value("http_config", $http_config);
});


run_tests;

__DATA__

=== TEST 1: add plugin
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                        "plugins": {
                            "http-logger": {
                                "uri": "http://127.0.0.1:1970/large_body",
                                "batch_max_size": 1,
                                "max_retry_count": 1,
                                "retry_delay": 2,
                                "buffer_duration": 2,
                                "inactive_timeout": 5,
                                "include_req_body": true,
                                "include_resp_body": false,
                                "max_req_body_bytes": 20649728,
                                "log_format": {
                                    "@timestamp": "$time_iso8601",
                                    "client_ip": "$remote_addr",
                                    "env": "$http_env",
                                    "host": "$host",
                                    "request": "$request",
                                    "request_body": "$request_body",
                                    "resp_content_type": "$sent_http_Content_Type"
                                }
                            }
                        },
                        "upstream": {
                            "nodes": {
                                "127.0.0.1:1982": 1
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



=== TEST 2: send large body
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local t    = require("lib.test_admin")
            local http = require("resty.http")

            local large_body = {
                "h", "e", "l", "l", "o"
            }

            local size_in_bytes = 2 * 1024 * 1024 -- 2MB
            for i = 1, size_in_bytes do
                large_body[i+5] = "l"
            end
            large_body = table.concat(large_body, "")

            local uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/hello"

            local httpc = http.new()
            local res, err = httpc:request_uri(uri,
                {
                    method = "POST",
                    body = large_body,
                }
            )
            ngx.print(res.body)
        }
    }
--- request
GET /t
--- response_body
hello world
--- error_log
body_size >= 2MB: true
--- no_error_log
fail to get request body: fail to open file
