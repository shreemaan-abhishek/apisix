use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_root_location();


add_block_preprocessor(sub {
    my ($block) = @_;

    my $extra_yaml_config = $block->extra_yaml_config // <<_EOC_;
plugins:
    - ht-ws-msg-pub
    - serverless-pre-function
plugin_attr:
    ht-ws-msg-pub:
        enable_log: true
        enable_log_rotate: true
        log_rotate:
            interval: 1
_EOC_

    $block->set_value("extra_yaml_config", $extra_yaml_config);

    if (!defined $block->request) {
        $block->set_value("request", "GET /t");
    }
});

run_tests();

__DATA__

=== TEST 1: support for enabling log rotate
--- config
    location /t {
        content_by_lua_block {
            ngx.sleep(3)
            local has_split_log_file = false
            local lfs = require("lfs")
            for file_name in lfs.dir(ngx.config.prefix() .. "/logs/") do
                if string.match(file_name, "__ht_msg_push.log$") then
                    has_split_log_file = true
                end
            end

            if not has_split_log_file then
                ngx.say("failed")
            else
                ngx.say("ok")
            end
        }
    }
--- timeout: 5
--- response_body
ok
