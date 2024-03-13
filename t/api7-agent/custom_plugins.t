use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_root_location();
no_shuffle();
log_level("info");
workers(2);

add_block_preprocessor(sub {
    my ($block) = @_;

    my $extra_init_by_lua_start = <<_EOC_;
require "agent.hook";
_EOC_

    $block->set_value("extra_init_by_lua_start", $extra_init_by_lua_start);

    my $http_config = $block->http_config // <<_EOC_;
lua_shared_dict config 5m;
_EOC_
    $block->set_value("http_config", $http_config);

    my $extra_init_by_lua = <<_EOC_;
    local server = require("lib.server")
    server.api_dataplane_heartbeat = function()
        ngx.say("{}")
    end

    server.api_dataplane_metrics = function()
    end

    server.apisix_prometheus_metrics = function()
        ngx.say('apisix_http_status{code="200",route="httpbin",matched_uri="/*",matched_host="nic.httpbin.org",service="",consumer="",node="172.30.5.135"} 61')
    end
_EOC_

    $block->set_value("extra_init_by_lua", $extra_init_by_lua);

    if ((!defined $block->error_log) && (!defined $block->no_error_log)) {
        $block->set_value("no_error_log", "[error]\n[alert]");
    }
});

run_tests;

__DATA__

=== TEST 1: create custom plugin test
--- config
location /t {
    content_by_lua_block {
        local core = require("apisix.core")
        local key = "/custom_plugins/test"
        local val = {
            name = "test",
            content = "local core = require(\"apisix.core\")\nlocal schema = {\n    type = \"object\",\n    properties = {\n        body = {\n            description = \"body to replace upstream response.\",\n            type = \"string\"\n        },\n    },\n}\nlocal plugin_name = \"test\"\nlocal _M = {\n    version = 0.1,\n    priority = 412,\n    name = plugin_name,\n    schema = schema,\n}\nfunction _M.check_schema(conf)\n    local ok, err = core.schema.check(schema, conf)\n    if not ok then\n        return false, err\n    end\n\n    return true\nend\nfunction _M.body_filter(conf, ctx)\n    if conf.body then\n        ngx.arg[1] = conf.body\n        ngx.arg[2] = true\n    end\nend\nfunction _M.header_filter(conf, ctx)\n    if conf.body then\n        core.response.clear_header_as_body_modified()\n    end\nend\nreturn _M\n"
        }
        local _, err = core.etcd.set(key, val)
        if err then
            ngx.say(err)
            return
        end

        ngx.say("done")
    }
}
--- request
GET /t
--- response_body
done



=== TEST 2: create route with test plugins
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- yaml_config
plugin_attr:
  prometheus:
    export_addr:
      port: 1980
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local core = require("apisix.core")
            assert(core.etcd.set("/plugins", {{name = "test"}}))

            ngx.sleep(0.2)

            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "plugins": {
                        "test": {
                            "body":"custom"
                        }
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    },
                    "uri": "/hello"
                }]]
            )

            if code >= 300 then
                ngx.status = code
            end

            if body ~= "passed" then
                ngx.say(body)
                return
            end

            local uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/hello"
            local http = require "resty.http"
            local httpc = http.new()
            local res = httpc:request_uri(uri)

            if res.body ~= "custom" then
                ngx.say(res.body)
                return
            end

            local key = "/custom_plugins/test"
            local val = {
                name = "test",
                content = "local core = require(\"apisix.core\")\nlocal schema = {\n    type = \"object\",\n    properties = {\n        body = {\n            description = \"body to replace upstream response.\",\n            type = \"string\"\n        },\n    },\n}\nlocal plugin_name = \"test\"\nlocal _M = {\n    version = 0.2,\n    priority = 412,\n    name = plugin_name,\n    schema = schema,\n}\nfunction _M.check_schema(conf)\n    local ok, err = core.schema.check(schema, conf)\n    if not ok then\n        return false, err\n    end\n\n    return true\nend\nfunction _M.body_filter(conf, ctx)\n    if conf.body then\n        ngx.arg[1] = \"update\"\n        ngx.arg[2] = true\n    end\nend\nfunction _M.header_filter(conf, ctx)\n    if conf.body then\n        core.response.clear_header_as_body_modified()\n    end\nend\nreturn _M\n"
            }
            local _, err = core.etcd.set(key, val)
            if err then
                ngx.say(err)
                return
            end

            ngx.sleep(2)

            local uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/hello"
            local http = require "resty.http"
            local httpc = http.new()
            local res = assert(httpc:request_uri(uri))

            if res.body ~= "update" then
                ngx.say(res.body)
                return
            end


            ngx.say("success")
        }
    }
--- request
GET /t
--- response_body
success
