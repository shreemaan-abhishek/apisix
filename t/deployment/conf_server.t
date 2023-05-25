#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
use t::APISIX 'no_plan';

worker_connections(256);

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!$block->request) {
        $block->set_value("request", "GET /t");
    }

});

run_tests();

__DATA__




=== TEST 6: check default SNI
--- http_config
server {
    listen 12345 ssl;
    ssl_certificate             cert/apisix.crt;
    ssl_certificate_key         cert/apisix.key;

    ssl_certificate_by_lua_block {
        local ngx_ssl = require "ngx.ssl"
        ngx.log(ngx.WARN, "Receive SNI: ", ngx_ssl.server_name())
    }

    location / {
        proxy_pass http://127.0.0.1:2379;
    }
}
--- config
    location /t {
        content_by_lua_block {
            local etcd = require("apisix.core.etcd")
            assert(etcd.set("/apisix/test", "foo"))
            local res = assert(etcd.get("/apisix/test"))
            ngx.say(res.body.node.value)
        }
    }
--- response_body
foo
--- yaml_config
deployment:
    role: traditional
    role_traditional:
        config_provider: etcd
    etcd:
        prefix: "/apisix"
        host:
            - https://127.0.0.1:12379
            - https://localhost:12345
        tls:
            verify: false
--- error_log
Receive SNI: localhost

