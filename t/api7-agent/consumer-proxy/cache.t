use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_root_location();
workers(1);

add_block_preprocessor(sub {
    my ($block) = @_;
    my $extra_init_by_lua_start = <<_EOC_;
require "agent.hook";
_EOC_

    $block->set_value("extra_init_by_lua_start", $extra_init_by_lua_start);

    my $extra_init_by_lua = <<_EOC_;
    local server = require("lib.server")
    server.api_dataplane_heartbeat = function()
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


        local conf_version = apisix.heartbeat_config_version or 0
        conf_version = conf_version + 1
        apisix.heartbeat_config_version = conf_version

        local consumer_proxy = ngx.shared["config"]:get("consumer_proxy")
        local enabled_consumer_proxy = consumer_proxy and true or false

        local resp_payload = {
            config = {
                config_version = conf_version,
                config_payload = {
                    apisix = {
                        ssl = {
                            key_encrypt_salt = {"1234567890abcdef"}
                        },
                        data_encryption = {
                            enable = true,
                            keyring = {"umse0chsxjqpjgdxp6xyvflyixqnkqwb"}
                        }
                    },
                    api7ee = {
                        consumer_proxy = {
                            enable = enabled_consumer_proxy
                        }
                    }
                }
            }
        }

        local core = require("apisix.core")
        core.log.info("agent heartbeat response: ", core.json.encode(resp_payload))
        ngx.say(core.json.encode(resp_payload))
    end

    server.api_dataplane_streaming_metrics = function()
        ngx.req.read_body()
        local data = ngx.req.get_body_data()
        ngx.log(ngx.NOTICE, "receive data plane metrics: ", data)

        local json_decode = require("toolkit.json").decode
        local payload = json_decode(data)

        if not payload.instance_id then
            ngx.log(ngx.ERR, "missing instance_id")
            return ngx.exit(400)
        end
        if not payload.metrics then
            ngx.log(ngx.ERR, "missing metrics")
            return ngx.exit(400)
        end
        ngx.log(ngx.NOTICE, "metrics size: ", #payload.metrics)
    end

    server.api_dataplane_consumer_query = function()
        local plugin_name = ngx.var.arg_plugin_name
        local key_value = ngx.var.arg_key_value
        if not plugin_name or not key_value then
            return ngx.exit(400)
        end

        if key_value == "500" then
            ngx.log(ngx.ERR, "query consumer error in nginx proxy")
            return ngx.exit(500)
        end

        ngx.log(ngx.INFO, "receive data plane consumer_query: ", plugin_name, ", ", key_value)

        local auth_plugin_payload = {
            ["key-auth"] = {
                ["auth-one"] = {
                    credential_id = "05ade19c-44ac-4d87-993c-c877dbce5d34",
                    consumer_name = "test",
                    labels = {},
                    username = "test",
                    plugins = {},
                    auth_conf = {
                        key = "ppXvv68X3XHOqe/D/cB5Xg=="
                    },
                    modifiedIndex = 111
                }
            }
        }

        local payload = auth_plugin_payload[plugin_name] and auth_plugin_payload[plugin_name][key_value]
        if not payload then
            ngx.log(ngx.WARN, "not found consumer in nginx proxy")
            return ngx.exit(404)
        end

        local core = require("apisix.core")
        ngx.say(core.json.encode(payload))
    end
_EOC_

    $block->set_value("extra_init_by_lua", $extra_init_by_lua);

    if (!$block->request) {
        if (!$block->stream_request) {
            $block->set_value("request", "GET /t");
        }
    }

    my $extra_yaml_config = <<_EOC_;
api7ee:
  telemetry:
    enable: false
  heartbeat_interval: 2
  consumer_proxy:
    enable: true
    cache_success_count: 512
    cache_success_ttl: 60
    cache_failure_count: 512
    cache_failure_ttl: 60
_EOC_

    $block->set_value("extra_yaml_config", $extra_yaml_config);

    if ((!defined $block->error_log) && (!defined $block->no_error_log)) {
        $block->set_value("no_error_log", "[error]");
    }
});

run_tests;

__DATA__

=== TEST 1: enable key-auth plugin
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "methods": ["GET"],
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1981": 1
                        },
                        "type": "roundrobin"
                    },
                    "plugins":{
                        "key-auth": {}
                    },
                    "uri": "/hello"
                }]]
                )

            if code <= 201 then
                ngx.status = 200
            end

            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 2: release consumer cache
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- config
    location /t {
        content_by_lua_block {
            ngx.shared["config"]:set("consumer_proxy", "true")

            local t = require("lib.test_admin").test
            for i = 1, 10 do
                local code, body = t('/hello',
                    ngx.HTTP_GET,
                    "",
                    nil,
                    {apikey = "auth-one"}
                )
                if code > 200 then
                    ngx.exit(500)
                end
                ngx.sleep(1)
            end
        }
    }
--- timeout: 13
--- request
GET /t
--- error_log
release consuemr cache, new config version: 1
release consuemr cache, new config version: 2
release consuemr cache, new config version: 3
release consuemr cache, new config version: 4
release consuemr cache, new config version: 5



=== TEST 3: switch to consumer proxy
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- config
    location /t {
        content_by_lua_block {
            ngx.shared["config"]:delete("consumer_proxy")

            local t = require("lib.test_admin").test
            local code, body = t('/hello',
                ngx.HTTP_GET,
                "",
                nil,
                {apikey = "auth-one"}
            )
            if code ~= 401 then
                ngx.exit(500)
            end

            ngx.shared["config"]:set("consumer_proxy", "true")
            ngx.sleep(2.5)

            local code, body = t('/hello',
                ngx.HTTP_GET,
                "",
                nil,
                {apikey = "auth-one"}
            )
            if code ~= 200 then
                ngx.exit(500)
            end
            ngx.say(body)
        }
    }
--- timeout: 13
--- request
GET /t
--- response_body
passed



=== TEST 4: switch off consumer proxy
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- config
    location /t {
        content_by_lua_block {
            ngx.shared["config"]:set("consumer_proxy", "true")

            local t = require("lib.test_admin").test
            local code, body = t('/hello',
                ngx.HTTP_GET,
                "",
                nil,
                {apikey = "auth-one"}
            )
            if code ~= 200 then
                ngx.exit(500)
            end

            -- switch off consumer proxy
            ngx.shared["config"]:delete("consumer_proxy")
            ngx.sleep(2.1)

            local code, body = t('/hello',
                ngx.HTTP_GET,
                "",
                nil,
                {apikey = "auth-one"}
            )
            if code ~= 401 then
                ngx.exit(500)
            end

            local code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "jack",
                    "plugins": {
                        "key-auth": {
                            "key": "auth-one2"
                        }
                    }
                }]]
                )

            if code >= 300 then
                ngx.exit(500)
            end

            local code, body = t('/hello',
                ngx.HTTP_GET,
                "",
                nil,
                {apikey = "auth-one2"}
            )
            if code ~= 200 then
                ngx.exit(500)
            end
            ngx.say(body)
        }
    }
--- timeout: 13
--- request
GET /t
--- response_body
passed



=== TEST 5: 404 will be cached
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- config
    location /t {
        content_by_lua_block {
            ngx.shared["config"]:set("consumer_proxy", "true")
            local t = require("lib.test_admin").test

            local codes = {}
            for i = 1, 5 do
                local code, body = t('/hello',
                    ngx.HTTP_GET,
                    "",
                    nil,
                    {apikey = "api7key-404"}
                )
                table.insert(codes, code)
            end
            ngx.say(table.concat(codes, ","))
        }
    }
--- timeout: 13
--- request
GET /t
--- response_body
401,401,401,401,401
--- grep_error_log eval
qr/not found consumer in nginx proxy/
--- grep_error_log_out
not found consumer in nginx proxy



=== TEST 6: 500 will not be cached
--- main_config
env API7_CONTROL_PLANE_TOKEN=a7ee-token;
env API7_CONTROL_PLANE_ENDPOINT_DEBUG=http://127.0.0.1:1980;
env API7_CONTROL_PLANE_SKIP_FIRST_HEARTBEAT_DEBUG=true;
--- config
    location /t {
        content_by_lua_block {
            ngx.shared["config"]:set("consumer_proxy", "true")
            local t = require("lib.test_admin").test

            local codes = {}
            for i = 1, 5 do
                local code, body = t('/hello',
                    ngx.HTTP_GET,
                    "",
                    nil,
                    {apikey = "500"}
                )
                table.insert(codes, code)
            end
            ngx.say(table.concat(codes, ","))
        }
    }
--- timeout: 13
--- request
GET /t
--- response_body
401,401,401,401,401
--- grep_error_log eval
qr/query consumer error in nginx proxy/
--- grep_error_log_out
query consumer error in nginx proxy
query consumer error in nginx proxy
query consumer error in nginx proxy
query consumer error in nginx proxy
query consumer error in nginx proxy
--- error_log
failed to fetch consumer from control plane
