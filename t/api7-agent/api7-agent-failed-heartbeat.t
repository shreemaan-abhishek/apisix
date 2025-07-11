use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_root_location();

add_block_preprocessor(sub {
    my ($block) = @_;

    my $extra_init_by_lua_start = <<_EOC_;
if require("ffi").os == "Linux" then
    local ngx_re = require("ngx.re")
    local old_ngx_re_opt = ngx_re.opt
    old_ngx_re_opt("jit_stack_size", 200 * 1024)

    -- Skip subsequent jit_stack_size changes
    ngx_re.opt = function(option, value)
        if option == "jit_stack_size" then return end
        old_ngx_re_opt(option, value)
    end
end
_EOC_

    $block->set_value("extra_init_by_lua_start", $extra_init_by_lua_start);

    if (!$block->request && !$block->stream_request) {
        $block->set_value("request", "GET /t");
    }
});
run_tests;

__DATA__

=== TEST 1: heartbeat error caught after panic
--- extra_init_by_lua
local http = require("socket.http")
local old_http_request = http.request
http.request = function(req_params)
    if req_params.url:find("/api/dataplane/heartbeat") then
        error("test panic")
    end
    return old_http_request(req_params)
end
require "agent.hook";
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1234;
--- config
    location /t {
        content_by_lua_block {
            ngx.say("ok")
        }
    }
--- error_log
heartbeat error:
test panic
