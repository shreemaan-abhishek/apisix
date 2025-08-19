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

    my $extra_init_by_lua = <<_EOC_;
    local resty_http = require("resty.http")
    local old_request_uri = resty_http.request_uri
    resty_http.request_uri = function(self, uri, opts)
        if uri:find("/api/dataplane/streaming_metrics") then
            error("test panic")
        end
        return old_request_uri(self, uri, opts)
    end
    require "agent.hook";
    local server = require("lib.server")
    server.api_dataplane_heartbeat = function()
        local core = require("apisix.core")
        ngx.req.read_body()
        local data = ngx.req.get_body_data()
        ngx.log(ngx.NOTICE, "receive data plane heartbeat: ", data)

        local json_decode = require("toolkit.json").decode
        local payload = json_decode(data)

        if not payload.instance_id then
            ngx.log(ngx.ERR, "missing instance_id")
            return ngx.exit(400)
        end
        if not payload.hostname then
            ngx.log(ngx.ERR, "missing hostname")
            return ngx.exit(400)
        end
        if not payload.ip then
            ngx.log(ngx.ERR, "missing ip")
            return ngx.exit(400)
        end
        if not payload.version then
            ngx.log(ngx.ERR, "missing version")
            return ngx.exit(400)
        end
        if not payload.control_plane_revision then
            ngx.log(ngx.ERR, "missing control_plane_revision")
            return ngx.exit(400)
        end
        if not payload.ports then
            ngx.log(ngx.ERR, "missing ports")
            return ngx.exit(400)
        end

        if payload.version == "3.1.1" then
            ngx.status = 403
            ngx.say(core.json.encode({
                error_msg = "gateway version not supported",
            }))
            return ngx.exit(403)
        end

        local resp_payload = {
            config = {
                config_version = 1,
                config_payload = {
                    apisix = {
                        ssl = {
                            key_encrypt_salt = {"1234567890abcdef"},
                        }
                    }
                }
            }
        }
        ngx.say(core.json.encode(resp_payload))
    end
_EOC_

    $block->set_value("extra_init_by_lua", $extra_init_by_lua);
    if (!$block->request && !$block->stream_request) {
        $block->set_value("request", "GET /t");
    }
});
run_tests;

__DATA__

=== TEST 1: metric error caught after panic
--- yaml_config
plugin_attr:
  prometheus:
    export_addr:
      port: 1980
--- config
    location /t {
        content_by_lua_block {
            ngx.say("ok")
        }
    }
--- wait: 17
--- error_log
upload metrics error
test panic
