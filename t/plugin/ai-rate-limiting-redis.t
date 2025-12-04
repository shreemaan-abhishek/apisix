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

log_level("info");
repeat_each(1);
no_long_string();
no_root_location();
workers(4);


my $resp_file = 't/assets/ai-proxy-response.json';
open(my $fh, '<', $resp_file) or die "Could not open file '$resp_file' $!";
my $resp = do { local $/; <$fh> };
close($fh);

print "Hello, World!\n";
print $resp;


add_block_preprocessor(sub {
    my ($block) = @_;

    if (!defined $block->request) {
        $block->set_value("request", "GET /t");
    }
    my $extra_init_worker_by_lua = <<_EOC_;
        require("lib.test_redis").flush_all()
_EOC_

    $block->set_value("extra_init_worker_by_lua", $extra_init_worker_by_lua);

    my $http_config = $block->http_config // <<_EOC_;
        server {
            server_name openai;
            listen 16724;

            default_type 'application/json';

            location /anything {
                content_by_lua_block {
                    local json = require("cjson.safe")

                    if ngx.req.get_method() ~= "POST" then
                        ngx.status = 400
                        ngx.say("Unsupported request method: ", ngx.req.get_method())
                    end
                    ngx.req.read_body()
                    local body = ngx.req.get_body_data()

                    if body ~= "SELECT * FROM STUDENTS" then
                        ngx.status = 503
                        ngx.say("passthrough doesn't work")
                        return
                    end
                    ngx.say('{"foo", "bar"}')
                }
            }

            location /v1/chat/completions {
                content_by_lua_block {
                    local json = require("cjson.safe")

                    if ngx.req.get_method() ~= "POST" then
                        ngx.status = 400
                        ngx.say("Unsupported request method: ", ngx.req.get_method())
                    end
                    ngx.req.read_body()
                    local body, err = ngx.req.get_body_data()
                    body, err = json.decode(body)

                    local test_type = ngx.req.get_headers()["test-type"]
                    if test_type == "options" then
                        if body.foo == "bar" then
                            ngx.status = 200
                            ngx.say("options works")
                        else
                            ngx.status = 500
                            ngx.say("model options feature doesn't work")
                        end
                        return
                    end

                    local header_auth = ngx.req.get_headers()["authorization"]
                    local query_auth = ngx.req.get_uri_args()["apikey"]

                    if header_auth ~= "Bearer token" and query_auth ~= "apikey" then
                        ngx.status = 401
                        ngx.say("Unauthorized")
                        return
                    end

                    if header_auth == "Bearer token" or query_auth == "apikey" then
                        ngx.req.read_body()
                        local body, err = ngx.req.get_body_data()
                        body, err = json.decode(body)

                        if not body.messages or #body.messages < 1 then
                            ngx.status = 400
                            ngx.say([[{ "error": "bad request"}]])
                            return
                        end

                        if body.messages[1].content == "write an SQL query to get all rows from student table" then
                            ngx.print("SELECT * FROM STUDENTS")
                            return
                        end

                        ngx.status = 200
                        ngx.say(string.format([[
{
  "choices": [
    {
      "finish_reason": "stop",
      "index": 0,
      "message": { "content": "1 + 1 = 2.", "role": "assistant" }
    }
  ],
  "created": 1723780938,
  "id": "chatcmpl-9wiSIg5LYrrpxwsr2PubSQnbtod1P",
  "model": "%s",
  "object": "chat.completion",
  "system_fingerprint": "fp_abc28019ad",
  "usage": { "completion_tokens": 5, "prompt_tokens": 8, "total_tokens": 10 }
}
                        ]], body.model))
                        return
                    end


                    ngx.status = 503
                    ngx.say("reached the end of the test suite")
                }
            }

            location /random {
                content_by_lua_block {
                    ngx.say("path override works")
                }
            }
        }
_EOC_

    $block->set_value("http_config", $http_config);
});

run_tests();

__DATA__

=== TEST 1: set route with Redis policy
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/ai",
                    "plugins": {
                        "ai-proxy": {
                            "provider": "openai",
                            "auth": {
                                "header": {
                                    "Authorization": "Bearer token"
                                }
                            },
                            "options": {
                                "model": "gpt-4"
                            },
                            "override": {
                                "endpoint": "http://localhost:16724"
                            },
                            "ssl_verify": false
                        },
                        "ai-rate-limiting": {
                            "limit": 30,
                            "time_window": 60,
                            "policy": "redis",
                            "redis_host": "127.0.0.1"
                        }
                    },
                    "upstream": {
                        "type": "roundrobin",
                        "nodes": {
                            "canbeanything.com": 1
                        }
                    }
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



=== TEST 2: reject the 4th request with Redis policy
--- pipelined_requests eval
[
    "POST /ai\n" . "{ \"messages\": [ { \"role\": \"system\", \"content\": \"You are a mathematician\" }, { \"role\": \"user\", \"content\": \"What is 1+1?\"} ] }",
    "POST /ai\n" . "{ \"messages\": [ { \"role\": \"system\", \"content\": \"You are a mathematician\" }, { \"role\": \"user\", \"content\": \"What is 1+1?\"} ] }",
    "POST /ai\n" . "{ \"messages\": [ { \"role\": \"system\", \"content\": \"You are a mathematician\" }, { \"role\": \"user\", \"content\": \"What is 1+1?\"} ] }",
    "POST /ai\n" . "{ \"messages\": [ { \"role\": \"system\", \"content\": \"You are a mathematician\" }, { \"role\": \"user\", \"content\": \"What is 1+1?\"} ] }",
]
--- more_headers
Authorization: Bearer token
--- error_code eval
[200, 200, 200, 503]
--- response_headers eval
[
    "X-AI-RateLimit-Remaining-ai-proxy-openai: 29",
    "X-AI-RateLimit-Remaining-ai-proxy-openai: 19",
    "X-AI-RateLimit-Remaining-ai-proxy-openai: 9",
    "X-AI-RateLimit-Remaining-ai-proxy-openai: 0",
]



=== TEST 3: set rejected_code to 403, rejected_msg to "rate limit exceeded" with Redis
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/ai",
                    "plugins": {
                        "ai-proxy": {
                            "provider": "openai",
                            "auth": {
                                "header": {
                                    "Authorization": "Bearer token"
                                }
                            },
                            "options": {
                                "model": "gpt-4"
                            },
                            "override": {
                                "endpoint": "http://localhost:16724"
                            },
                            "ssl_verify": false
                        },
                        "ai-rate-limiting": {
                            "limit": 30,
                            "time_window": 60,
                            "rejected_code": 403,
                            "rejected_msg": "rate limit exceeded",
                            "policy": "redis",
                            "redis_host": "127.0.0.1"
                        }
                    },
                    "upstream": {
                        "type": "roundrobin",
                        "nodes": {
                            "canbeanything.com": 1
                        }
                    }
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



=== TEST 4: check code and message with Redis
--- pipelined_requests eval
[
    "POST /ai\n" . "{ \"messages\": [ { \"role\": \"system\", \"content\": \"You are a mathematician\" }, { \"role\": \"user\", \"content\": \"What is 1+1?\"} ] }",
    "POST /ai\n" . "{ \"messages\": [ { \"role\": \"system\", \"content\": \"You are a mathematician\" }, { \"role\": \"user\", \"content\": \"What is 1+1?\"} ] }",
    "POST /ai\n" . "{ \"messages\": [ { \"role\": \"system\", \"content\": \"You are a mathematician\" }, { \"role\": \"user\", \"content\": \"What is 1+1?\"} ] }",
    "POST /ai\n" . "{ \"messages\": [ { \"role\": \"system\", \"content\": \"You are a mathematician\" }, { \"role\": \"user\", \"content\": \"What is 1+1?\"} ] }",
]
--- more_headers
Authorization: Bearer token
--- error_code eval
[200, 200, 200, 403]
--- response_body eval
[
    qr/\{ "content": "1 \+ 1 = 2\.", "role": "assistant" \}/,
    qr/\{ "content": "1 \+ 1 = 2\.", "role": "assistant" \}/,
    qr/\{ "content": "1 \+ 1 = 2\.", "role": "assistant" \}/,
    qr/\{"error_msg":"rate limit exceeded"\}/,
]



=== TEST 5: set route with Redis Cluster policy
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/ai",
                    "plugins": {
                        "ai-proxy": {
                            "provider": "openai",
                            "auth": {
                                "header": {
                                    "Authorization": "Bearer token"
                                }
                            },
                            "options": {
                                "model": "gpt-4"
                            },
                            "override": {
                                "endpoint": "http://localhost:16724"
                            },
                            "ssl_verify": false
                        },
                        "ai-rate-limiting": {
                            "limit": 30,
                            "time_window": 60,
                            "policy": "redis-cluster",
                            "redis_cluster_nodes": [
                                "127.0.0.1:5000",
                                "127.0.0.1:5002"
                            ],
                            "redis_cluster_name": "redis-cluster-1"
                        }
                    },
                    "upstream": {
                        "type": "roundrobin",
                        "nodes": {
                            "canbeanything.com": 1
                        }
                    }
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



=== TEST 6: reject request with Redis Cluster policy
--- pipelined_requests eval
[
    "POST /ai\n" . "{ \"messages\": [ { \"role\": \"system\", \"content\": \"You are a mathematician\" }, { \"role\": \"user\", \"content\": \"What is 1+1?\"} ] }",
    "POST /ai\n" . "{ \"messages\": [ { \"role\": \"system\", \"content\": \"You are a mathematician\" }, { \"role\": \"user\", \"content\": \"What is 1+1?\"} ] }",
    "POST /ai\n" . "{ \"messages\": [ { \"role\": \"system\", \"content\": \"You are a mathematician\" }, { \"role\": \"user\", \"content\": \"What is 1+1?\"} ] }",
    "POST /ai\n" . "{ \"messages\": [ { \"role\": \"system\", \"content\": \"You are a mathematician\" }, { \"role\": \"user\", \"content\": \"What is 1+1?\"} ] }",
]
--- more_headers
Authorization: Bearer token
--- error_code eval
[200, 200, 200, 503]
--- response_headers eval
[
    "X-AI-RateLimit-Remaining-ai-proxy-openai: 29",
    "X-AI-RateLimit-Remaining-ai-proxy-openai: 19",
    "X-AI-RateLimit-Remaining-ai-proxy-openai: 9",
    "X-AI-RateLimit-Remaining-ai-proxy-openai: 0",
]



=== TEST 7: set route with Redis Sentinel policy
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/ai",
                    "plugins": {
                        "ai-proxy": {
                            "provider": "openai",
                            "auth": {
                                "header": {
                                    "Authorization": "Bearer token"
                                }
                            },
                            "options": {
                                "model": "gpt-4"
                            },
                            "override": {
                                "endpoint": "http://localhost:16724"
                            },
                            "ssl_verify": false
                        },
                        "ai-rate-limiting": {
                            "limit": 30,
                            "time_window": 60,
                            "rejected_code": 503,
                            "key": "remote_addr",
                            "policy": "redis-sentinel",
                            "redis_sentinels": [
                                 {"host": "127.0.0.1", "port": 26379}
                             ],
                             "redis_master_name": "mymaster",
                             "redis_role": "master"
                        }
                    },
                    "upstream": {
                        "type": "roundrobin",
                        "nodes": {
                            "canbeanything.com": 1
                        }
                    }
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



=== TEST 8: reject the 4th request with Redis policy
--- pipelined_requests eval
[
    "POST /ai\n" . "{ \"messages\": [ { \"role\": \"system\", \"content\": \"You are a mathematician\" }, { \"role\": \"user\", \"content\": \"What is 1+1?\"} ] }",
    "POST /ai\n" . "{ \"messages\": [ { \"role\": \"system\", \"content\": \"You are a mathematician\" }, { \"role\": \"user\", \"content\": \"What is 1+1?\"} ] }",
    "POST /ai\n" . "{ \"messages\": [ { \"role\": \"system\", \"content\": \"You are a mathematician\" }, { \"role\": \"user\", \"content\": \"What is 1+1?\"} ] }",
    "POST /ai\n" . "{ \"messages\": [ { \"role\": \"system\", \"content\": \"You are a mathematician\" }, { \"role\": \"user\", \"content\": \"What is 1+1?\"} ] }",
]
--- more_headers
Authorization: Bearer token
--- error_code eval
[200, 200, 200, 503]
--- response_headers eval
[
    "X-AI-RateLimit-Remaining-ai-proxy-openai: 29",
    "X-AI-RateLimit-Remaining-ai-proxy-openai: 19",
    "X-AI-RateLimit-Remaining-ai-proxy-openai: 9",
    "X-AI-RateLimit-Remaining-ai-proxy-openai: 0",
]



=== TEST 9: setup route with rules
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "uri": "/ai",
                    "plugins": {
                        "ai-proxy-multi": {
                            "instances": [
                                {
                                    "name": "deepseek",
                                    "provider": "openai",
                                    "weight": 1,
                                    "auth": {
                                        "header": {
                                            "Authorization": "Bearer token"
                                        }
                                    },
                                    "override": {
                                        "endpoint": "http://localhost:16724"
                                    }
                                }
                            ],
                            "ssl_verify": false
                        },
                        "ai-rate-limiting": {
                            "policy": "redis",
                            "redis_host": "127.0.0.1",
                            "rejected_code": 429,
                            "rules": [
                                {
                                    "count": 20,
                                    "time_window": 10,
                                    "key": "${http_user}"
                                },
                                {
                                    "count": "${http_count ?? 30}",
                                    "time_window": "${http_window ?? 10}",
                                    "key": "${http_project}"
                                }
                            ]
                        }
                    },
                    "upstream": {
                        "type": "roundrobin",
                        "nodes": {
                            "canbeanything.com": 1
                        }
                    }
                }]]
            )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 10: request to confirm rules work
--- config
    location /t {
        content_by_lua_block {
            local http = require("resty.http")

            local run_tests = function(name, test_cases)
                local httpc = http.new()
                for i, case in ipairs(test_cases) do
                    case.headers["Content-Type"] = "application/json"
                    local res = httpc:request_uri(
                        "http://127.0.0.1:" .. ngx.var.server_port .. "/ai",
                        {
                            method = "POST",
                            body = [[{
                                "messages": [
                                    { "role": "system", "content": "You are a mathematician" },
                                    { "role": "user", "content": "What is 1+1?" }
                                ]
                            }]],
                            headers = case.headers
                        }
                    )
                    if res.status ~= case.code then
                        ngx.say(name .. ": " .. i  .. "th request should return " .. case.code .. ", but got " .. res.status)
                        ngx.exit(500)
                    end
                end
            end

            -- for user rule
            run_tests("user_rule", {
                { headers = { ["user"] = "jack" }, code = 200 },
                { headers = { ["user"] = "jack" }, code = 200 },
                { headers = { ["user"] = "jack" }, code = 429 },
                { headers = { ["user"] = "rose" }, code = 200 },
                { headers = { ["user"] = "rose" }, code = 200 },
                { headers = { ["user"] = "rose" }, code = 429 },
            })

            -- for project rule with default variable value
            run_tests("project_rule_default_value", {
                { headers = { ["project"] = "apisix" }, code = 200 },
                { headers = { ["project"] = "apisix" }, code = 200 },
                { headers = { ["project"] = "apisix" }, code = 200 },
                { headers = { ["project"] = "apisix" }, code = 429 },
            })

            -- for project rule with custom variable value
            run_tests("project_rule_custom_variables", {
                { headers = { ["project"] = "linux", ["count"] = "20", ["window"] = "2" }, code = 200 },
                { headers = { ["project"] = "linux", ["count"] = "20", ["window"] = "2" }, code = 200 },
                { headers = { ["project"] = "linux", ["count"] = "20", ["window"] = "2" }, code = 429 },
            })
            ngx.sleep(2)
            run_tests("project_rule_custom_variables2", {
                { headers = { ["project"] = "linux", ["count"] = "20", ["window"] = "2" }, code = 200 },
                { headers = { ["project"] = "linux", ["count"] = "20", ["window"] = "2" }, code = 200 },
                { headers = { ["project"] = "linux", ["count"] = "20", ["window"] = "2" }, code = 429 },
            })

            -- no rule hit
            run_tests("no_rules", {
                { headers = {}, code = 500 },
            })

            ngx.say("passed")
        }
    }
--- request
GET /t
--- timeout: 10
--- response_body
passed
--- error_log
failed to get rate limit rules
