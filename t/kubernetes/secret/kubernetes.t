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

BEGIN {
    our $token_file = "/tmp/var/run/secrets/kubernetes.io/serviceaccount/token";
    our $token_value = eval {`cat $token_file 2>/dev/null`};
}

use t::APISIX 'no_plan';

repeat_each(1);
log_level('info');
no_root_location();
no_shuffle();
workers(4);

add_block_preprocessor(sub {
    my ($block) = @_;

    my $main_config = $block->main_config // <<_EOC_;
env KUBERNETES_SERVICE_HOST=127.0.0.1;
env KUBERNETES_SERVICE_PORT=6443;
env KUBERNETES_CLIENT_TOKEN=$::token_value;
env KUBERNETES_CLIENT_TOKEN_FILE=$::token_file;
_EOC_

    $block->set_value("main_config", $main_config);

    my $config = $block->config // <<_EOC_;
        location /operators {
            content_by_lua_block {
                local http = require("resty.http")
                local core = require("apisix.core")
                local ipairs = ipairs

                ngx.req.read_body()
                local request_body = ngx.req.get_body_data()
                local operators = core.json.decode(request_body)

                core.log.info("get body ", request_body)
                core.log.info("get operators ", #operators)
                for _, op in ipairs(operators) do
                    local method, path, body
                    local headers = {
                        ["Host"] = "127.0.0.1:6445",
                        ["Content-Type"] = "application/json"
                    }

                    method = op.method
                    path = op.path
                    body = core.json.encode(op.body, true)
                    core.log.info("body ", body)

                    local httpc = http.new()
                    core.log.info("begin to connect ", "127.0.0.1:6445")
                    local ok, message = httpc:connect({
                        scheme = "http",
                        host = "127.0.0.1",
                        port = 6445,
                    })
                    if not ok then
                        core.log.error("connect 127.0.0.1:6445 failed, message : ", message)
                        ngx.say("FAILED")
                        return 500
                    end
                    local res, err = httpc:request({
                        method = method,
                        path = path,
                        headers = headers,
                        body = body,
                    })
                    if err ~= nil then
                        core.log.err("operator k8s cluster error: ", err)
                        return 500
                    end
                    if res.status ~= 200 and res.status ~= 201 and res.status ~= 409 then
                        core.log.error("operator k8s cluster error: ", res.status, res.body)
                        ngx.say("FAILED")
                        return res.status
                    end
                end
                ngx.say("done")
            }
        }

_EOC_

    $block->set_value("config", $config);

});

run_tests();

__DATA__

=== TEST 1: schema validation
--- request
GET /t
--- config
    location /t {
        content_by_lua_block {
            local test_cases = {
                {apiserver_addr = "http://127.0.0.1:6443"},
                {token = "test-token"},
                {token_file = "/path/to/token"},
                {apiserver_addr = "http://127.0.0.1:6443", token = "test-token"},
                {apiserver_addr = "http://127.0.0.1:6443", token_file = "/path/to/token"},
                {apiserver_addr = "http://127.0.0.1:6443", token = "test-token", token_file = "/path/to/token"},
                {apiserver_addr = 123, token = "test-token"},
                {apiserver_addr = "http://127.0.0.1:6443", token = 123},
                {apiserver_addr = "http://127.0.0.1:6443", token_file = 123},
            }
            local kubernetes = require("apisix.secret.kubernetes")
            local core = require("apisix.core")
            local schema = kubernetes.schema

            for _, conf in ipairs(test_cases) do
                local ok, err = core.schema.check(schema, conf)
                ngx.say(ok and "valid" or err)
            end
        }
    }
--- response_body
value should match only one schema, but matches none
value should match only one schema, but matches none
value should match only one schema, but matches none
valid
valid
value should match only one schema, but matches both schemas 1 and 2
property "apiserver_addr" validation failed: wrong type: expected string, got number
property "token" validation failed: wrong type: expected string, got number
property "token_file" validation failed: wrong type: expected string, got number



=== TEST 2: check key format validation
--- request
GET /t
--- config
    location /t {
        content_by_lua_block {
            local kubernetes = require("apisix.secret.kubernetes")
            local conf = {
                apiserver_addr = "https://127.0.0.1:6443",
                token = "test-token"
            }

            local test_keys = {
                "invalid-key",
                "/missing-namespace",
                "namespace//missing-secret-name",
                "namespace/secret-name/",
                "//"
            }

            for _, key in ipairs(test_keys) do
                local data, err = kubernetes.get(conf, key)
                if err then
                    ngx.say("Error for key '" .. key .. "': " .. err)
                else
                    ngx.say("Success for key '" .. key .. "': " .. (data or "nil"))
                end
            end
        }
    }
--- response_body
Error for key 'invalid-key': invalid key format, expected: namespace/secret_name/data_key, got: invalid-key
Error for key '/missing-namespace': invalid key format, expected: namespace/secret_name/data_key, got: /missing-namespace
Error for key 'namespace//missing-secret-name': secret_name cannot be empty, key: namespace//missing-secret-name
Error for key 'namespace/secret-name/': data_key cannot be empty, key: namespace/secret-name/
Error for key '//': namespace cannot be empty, key: //



=== TEST 3: store secret into kubernetes using /operators
--- request
POST /operators
[
    {
        "method": "POST",
        "path": "/api/v1/namespaces/default/secrets",
        "body": {
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {
                "name": "test-secret",
                "namespace": "default"
            },
            "data": {
                "username": "YWRtaW4=",
                "password": "c2VjcmV0MTIz"
            }
        }
    }
]
--- response_body
done



=== TEST 4: get secret from kubernetes secret provider
--- config
    location /t {
        content_by_lua_block {
            local kubernetes = require("apisix.secret.kubernetes")

            -- use token
            local conf1 = {
                apiserver_addr = "https://127.0.0.1:6443",
                token = "$ENV://KUBERNETES_CLIENT_TOKEN"
            }

            -- use token_file
            local conf2 = {
                apiserver_addr = "https://127.0.0.1:6443",
                token_file = "/tmp/var/run/secrets/kubernetes.io/serviceaccount/token"
            }

            local username, err = kubernetes.get(conf1, "default/test-secret/username")
            if err then
                ngx.say("Error getting username: ", err)
            else
                ngx.say("Username: ", username)
            end

            local password, err = kubernetes.get(conf1, "default/test-secret/password")
            if err then
                ngx.say("Error getting password: ", err)
            else
                ngx.say("Password: ", password)
            end

            local username, err = kubernetes.get(conf2, "default/test-secret/username")
            if err then
                ngx.say("Error getting username with token_file: ", err)
            else
                ngx.say("Username with token_file: ", username)
            end

            -- test nonexistent key
            local nonexistent, err = kubernetes.get(conf1, "default/test-secret/nonexistent")
            if err then
                ngx.say("Error getting nonexistent key: ", err)
            else
                ngx.say("Nonexistent key: ", nonexistent)
            end

            -- test not found secret
            local notfound, err = kubernetes.get(conf1, "default/not-found/username")
            if err then
                ngx.print("Error getting not-found secret: ", err)
            else
                ngx.print("Not found secret: ", notfound)
            end
        }
    }
--- request
GET /t
--- response_body
Username: admin
Password: secret123
Username with token_file: admin
Error getting nonexistent key: key not found in Secret data: nonexistent
Error getting not-found secret: failed to retrieve data from Kubernetes Secret: Kubernetes API returned non-200 status: 404, body: {"kind":"Status","apiVersion":"v1","metadata":{},"status":"Failure","message":"secrets \"not-found\" not found","reason":"NotFound","details":{"name":"not-found","kind":"secrets"},"code":404}



=== TEST 5: invalid token
--- config
    location /t {
        content_by_lua_block {
            local kubernetes = require("apisix.secret.kubernetes")

            local conf = {
                apiserver_addr = "https://127.0.0.1:6443",
                token = "invalid-token"
            }

            local username, err = kubernetes.get(conf, "default/test-secret/username")
            if err then
                ngx.print("Error: ", err)
            else
                ngx.print("Username: ", username)
            end
        }
    }
--- request
GET /t
--- response_body
Error: failed to retrieve data from Kubernetes Secret: Kubernetes API returned non-200 status: 401, body: {"kind":"Status","apiVersion":"v1","metadata":{},"status":"Failure","message":"Unauthorized","reason":"Unauthorized","code":401}



=== TEST 6: invalid token file
--- config
    location /t {
        content_by_lua_block {
            local kubernetes = require("apisix.secret.kubernetes")

            local conf = {
                apiserver_addr = "https://127.0.0.1:6443",
                token_file = "/path/to/nonexistent/token"
            }

            local username, err = kubernetes.get(conf, "default/test-secret/username")
            if err then
                ngx.print("Error: ", err)
            else
                ngx.print("Username: ", username)
            end
        }
    }
--- request
GET /t
--- response_body eval
qr/Error: failed to retrieve data from Kubernetes Secret: .* error info:.*\/path\/to\/nonexistent\/token: No such file or directory/



=== TEST 7: error when API server is unreachable
--- request
GET /t
--- config
    location /t {
        content_by_lua_block {
            local kubernetes = require("apisix.secret.kubernetes")

            local conf = {
                apiserver_addr = "http://127.0.0.1:65535",
                token = "$ENV://KUBERNETES_CLIENT_TOKEN"
            }

            local value, err = kubernetes.get(conf, "default/test-secret/username")
            if err then
                ngx.say("Error: ", err)
            else
                ngx.say("Value: ", value)
            end
        }
    }
--- response_body
Error: failed to retrieve data from Kubernetes Secret: failed to request Kubernetes API: connection refused



=== TEST 8: add secret provider && consumer && check
--- request
GET /t
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test

            local code, body = t('/apisix/admin/secrets/kubernetes/mysecret',
                ngx.HTTP_PUT,
                [[{
                    "apiserver_addr": "https://127.0.0.1:6443",
                    "token": "$ENV://KUBERNETES_CLIENT_TOKEN"
                }]]
            )
            if code >= 300 then
                ngx.status = code
                return ngx.say(body)
            end

            code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "jack",
                    "plugins": {
                        "key-auth": {
                            "key": "$secret://kubernetes/mysecret/default/test-secret/password"
                        }
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                return ngx.say(body)
            end

            local secret = require("apisix.secret")
            local value = secret.fetch_by_uri("$secret://kubernetes/mysecret/default/test-secret/password")
            if value then
                ngx.say("Secret value: ", value)
            else
                ngx.say("Failed to fetch secret")
            end

            local code, body = t('/apisix/admin/secrets/kubernetes/mysecret', ngx.HTTP_DELETE)
            if code >= 300 then
                ngx.status = code
                return ngx.say(body)
            end

            ngx.sleep(0.5)

            local value = secret.fetch_by_uri("$secret://kubernetes/mysecret/default/test-secret/password")
            if value then
                ngx.say("Secret still exists: ", value)
            else
                ngx.say("Secret successfully deleted")
            end

            ngx.say("done")
        }
    }
--- response_body
Secret value: secret123
Secret successfully deleted
done



=== TEST 9: create consumer and route
--- request
GET /t
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test

            local code, body = t('/apisix/admin/secrets/kubernetes/mysecret',
                ngx.HTTP_PUT,
                [[{
                    "apiserver_addr": "https://127.0.0.1:6443",
                    "token": "$ENV://KUBERNETES_CLIENT_TOKEN"
                }]]
            )
            if code >= 300 then
                ngx.status = code
                return ngx.say(body)
            end

            code, body = t('/apisix/admin/consumers',
                ngx.HTTP_PUT,
                [[{
                    "username": "jack",
                    "plugins": {
                        "key-auth": {
                            "key": "$secret://kubernetes/mysecret/default/test-secret/password"
                        }
                    }
                }]]
            )

            if code >= 300 then
                ngx.status = code
                return ngx.say(body)
            end

            code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/hello",
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1981": 1
                        },
                        "type": "roundrobin"
                    },
                    "plugins": {
                        "key-auth": {}
                    }
                }]]
            )

            if code >= 300 then
                ngx.status = code
                return ngx.say(body)
            end

            ngx.say("done")
        }
    }
--- response_body
done



=== TEST 10: request with invaild-key
--- request
GET /hello
--- more_headers
apikey: invalid-key
--- error_code: 401
--- response_body
{"message":"Invalid API key in request"}



=== TEST 11: request with correct key
--- request
GET /hello
--- more_headers
apikey: secret123
--- response_body
hello world
