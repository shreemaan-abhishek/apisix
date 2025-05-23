BEGIN {
    $ENV{API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG} = "true";
}
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

    if (!defined $block->extra_init_by_lua_start) {
        $block->set_value("extra_init_by_lua_start", $extra_init_by_lua_start);
    }

    my $extra_init_by_lua = <<_EOC_;
    local server = require("lib.server")
    server.api_dataplane_heartbeat = function()
        ngx.say("{}")
    end

    server.api_dataplane_streaming_metrics = function()
    end

    server.apisix_collect_nginx_status = function()
        local prometheus = require("apisix.plugins.prometheus.exporter")
        prometheus.collect_api_specific_metrics()
    end

    server.apisix_nginx_status = function()
        ngx.say([[
Active connections: 6
server accepts handled requests
 11 22 23
Reading: 0 Writing: 6 Waiting: 0
]])
    end
_EOC_

    $block->set_value("extra_init_by_lua", $extra_init_by_lua);

    my $extra_yaml_config = $block->extra_yaml_config // <<_EOC_;
plugin_attr:
  prometheus:
    export_addr:
      port: 1980
_EOC_

    $block->set_value("extra_yaml_config", $extra_yaml_config);

    if ((!defined $block->error_log) && (!defined $block->no_error_log)) {
        $block->set_value("no_error_log", "[error]\n[alert]");
    }
});

run_tests;

__DATA__

=== TEST 1: create custom plugin test
--- extra_init_by_lua_start
--- extra_yaml_config
apisix:
  lua_module_hook: ""
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
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local core = require("apisix.core")
            assert(core.etcd.set("/plugins", {{name = "test", is_custom = true}}))

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



=== TEST 3: generate bytecode file from test custom plugin
--- exec
luajit -bg t/api7-agent/testdata/test.lua t/api7-agent/testdata/test.luac



=== TEST 4: create route with custom plugin in bytecode form
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local core = require("apisix.core")

            local file, err = io.open("t/api7-agent/testdata/test.luac", "rb")
            if not file then
                ngx.say(err)
                return
            end

            local data, err = file:read("*all")
            file:close()
            if not data then
                ngx.say(err)
                return
            end

            local key = "/custom_plugins/test"
            local val = {
                name = "test",
                content = ngx.encode_base64(data)
            }
            local _, err = core.etcd.set(key, val)
            if err then
                ngx.say(err)
                return
            end

            assert(core.etcd.set("/plugins", {{name = "test", is_custom = true}}))

            ngx.sleep(0.2)

            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "plugins": {
                        "test": {
                            "body":"binary test"
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

            ngx.say("success")
        }
    }
--- request
GET /t
--- response_body
success



=== TEST 5: request route with binary custom plugin
--- request
GET /hello
--- response_body chomp
binary test



=== TEST 6: update plugin list first
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local core = require("apisix.core")
            assert(core.etcd.set("/plugins", {{name = "test2", is_custom = true}}))

            ngx.sleep(0.2)

            local key = "/custom_plugins/test2"
            local val = {
                name = "test2",
                content = "local core = require(\"apisix.core\")\nlocal schema = {\n    type = \"object\",\n    properties = {\n        body = {\n            description = \"body to replace upstream response.\",\n            type = \"string\"\n        },\n    },\n}\nlocal plugin_name = \"test2\"\nlocal _M = {\n    version = 0.2,\n    priority = 412,\n    name = plugin_name,\n    schema = schema,\n}\nfunction _M.check_schema(conf)\n    local ok, err = core.schema.check(schema, conf)\n    if not ok then\n        return false, err\n    end\n\n    return true\nend\nfunction _M.body_filter(conf, ctx)\n    if conf.body then\n        ngx.arg[1] = \"test2\"\n        ngx.arg[2] = true\n    end\nend\nfunction _M.header_filter(conf, ctx)\n    if conf.body then\n        core.response.clear_header_as_body_modified()\n    end\nend\nreturn _M\n"
            }
            local _, err = core.etcd.set(key, val)
            if err then
                ngx.say(err)
                return
            end

            ngx.sleep(0.2)

            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "plugins": {
                        "test2": {
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

            if res.body ~= "test2" then
                ngx.say(res.body)
                return
            end

            ngx.say("success")

            -- clear test data to avoid affecting subsequent case execution
            assert(core.etcd.delete("/plugins"))
        }
    }
--- request
GET /t
--- response_body
success
--- error_log
could not find custom plugin [test2], it might be due to the order of etcd events, will retry loading when custom plugin available



=== TEST 7: bad lua code
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local key = "/custom_plugins/bad"
            local val = {
                name = "bad",
                content = ngx.encode_base64("bad lua code")
            }
            local _, err = core.etcd.set(key, val)
            if err then
                ngx.say(err)
                return
            end

            ngx.sleep(1)

            ngx.say("success")
        }
    }
--- request
GET /t
--- response_body
success
--- error_log
failed to load plugin string[string "bad lua code"]
failed to check item data of [/apisix/custom_plugins]



=== TEST 8: Internal errors in plugin_func when calling custom_plugin will not affect loading of other plugins
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local core = require("apisix.core")

            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "plugins": {
                        "echo": {
                            "body": "inject body"
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

            local uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/hello"
            local http = require "resty.http"
            local httpc = http.new()
            local res = httpc:request_uri(uri)
            ngx.say(res.body)

            -- Simulate uploading custom plugin:
            -- 1) Write ETCD /custom plugin to upload custom_plugin;
            -- 2) Update ETCD /plugins.
            -- NOTE: Only for simulation, not for production
            local key = "/custom_plugins/error-plugin"
            local val = {
                name = "error-plugin",
                content = [[
                    local invalid_module = require("unknown-module")
                    local core = require("apisix.core")
                    local schema = {
                        type = "object",
                        properties = {
                            body = {
                                description = "body to replace upstream response.",
                                type = "string"
                            },
                        },
                    }
                    local plugin_name = "error-plugin"
                    local _M = {
                        version = 0.1,
                        priority = 412,
                        name = plugin_name,
                        schema = schema,
                    }
                    function _M.check_schema(conf)
                        local ok, err = core.schema.check(schema, conf)
                        if not ok then
                            return false, err
                        end

                        return true
                    end
                    return _M
                    ]]
            }
            local _, err = core.etcd.set(key, val)
            if err then
                ngx.say(err)
                return
            end
            ngx.sleep(0.5)

            assert(core.etcd.set("/plugins", {{name = "echo"}, {name = "error-plugin", is_custom = true}}))
            ngx.sleep(0.5)

            if body ~= "passed" then
                ngx.say(body)
                return
            end

            local res = httpc:request_uri(uri)
            ngx.say(res.body)
        }
    }
--- request
GET /t
--- response_body
inject body
inject body
--- error_log
failed to create custom plugin instance: error-plugin
failed to load plugin [error-plugin] err: [string "error-plugin"]:1: module 'unknown-module' not found
