use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_root_location();

add_block_preprocessor(sub {
    my ($block) = @_;

    # setup default conf.yaml
    my $extra_yaml_config = $block->extra_yaml_config // <<_EOC_;
plugins:
    - api7-agent
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

=== TEST 1: plugin attr schema check
--- yaml_config
plugin_attr:
  api7-agent:
    endpoint: 123
--- config
    location /t {
        content_by_lua_block {
            ngx.say("ok")
        }
    }
--- error_log
failed to check the plugin_attr[api7-agent]



=== TEST 2: heartbeat failed
--- yaml_config
plugin_attr:
  api7-agent:
    endpoint: http://127.0.0.1:1234
--- config
    location /t {
        content_by_lua_block {
            ngx.say("ok")
        }
    }
--- wait: 12
--- error_log
heartbeat failed



=== TEST 3: heartbeat success
--- yaml_config
plugin_attr:
  api7-agent:
    endpoint: http://127.0.0.1:1980
--- config
    location /t {
        content_by_lua_block {
            ngx.say("ok")
        }
    }
--- extra_init_by_lua
    local server = require("lib.server")
    server.dataplane_heartbeat = function()
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
	    if not payload.conf_server_revision then
		ngx.log(ngx.ERR, "missing conf_server_revision")
		return ngx.exit(400)
	    end
	    if not payload.ports then
		ngx.log(ngx.ERR, "missing ports")
		return ngx.exit(400)
	    end
    end
--- wait: 12
--- error_log
receive data plane heartbeat
heartbeat successfully
