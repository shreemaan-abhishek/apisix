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


add_block_preprocessor(sub {
    my ($block) = @_;

    if (!defined $block->request) {
        $block->set_value("request", "GET /t");
    }

    my $http_config = $block->http_config // <<_EOC_;
        server {
            listen 6724;

            default_type 'application/json';

            location /v1/chat/completions {
                content_by_lua_block {
                    ngx.status = 200
                    ngx.say([[
{
"choices": [
{
  "finish_reason": "stop",
  "index": 0,
  "message": { "content": "I will kill you.", "role": "assistant" }
}
],
"created": 1723780938,
"id": "chatcmpl-9wiSIg5LYrrpxwsr2PubSQnbtod1P",
"model": "gpt-3.5-turbo",
"object": "chat.completion",
"usage": { "completion_tokens": 5, "prompt_tokens": 8, "total_tokens": 10 }
}
                    ]])
                }
            }

            location / {
                content_by_lua_block {
                    local core = require("apisix.core")
                    ngx.req.read_body()
                    local body, err = ngx.req.get_body_data()
                    if not body then
                        ngx.status(400)
                        return
                    end

                    ngx.status = 200
                    if core.string.find(body, "kill") then
                        ngx.say([[
{
  "Message": "OK",
  "Data": {
    "Advice": [
      {
        "HitLabel": "violent_incidents",
        "Answer": "As an AI language model, I cannot write unethical or controversial content for you."
      }
    ],
    "RiskLevel": "high",
    "Result": [
      {
        "RiskWords": "kill",
        "Description": "suspected extremist content",
        "Confidence": 100.0,
        "Label": "violent_incidents"
      }
    ]
  },
  "Code": 200
}
                    ]])
                    else
                        ngx.say([[
{
  "RequestId": "3262D562-1FBA-5ADF-86CB-3087603A4DF3",
  "Message": "OK",
  "Data": {
    "RiskLevel": "none",
    "Result": [
      {
        "Description": "no risk detected",
        "Label": "nonLabel"
      }
    ]
  },
  "Code": 200
}
                    ]])
                    end
                }
            }
        }
_EOC_

    $block->set_value("http_config", $http_config);
});

run_tests();

__DATA__

=== TEST 1: check prompt in request
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/chat",
                    "plugins": {
                      "ai-proxy": {
                          "provider": "openai",
                          "auth": {
                              "header": {
                                  "Authorization": "Bearer wrongtoken"
                              }
                          },
                          "override": {
                              "endpoint": "http://localhost:6724"
                          }
                      },
                      "ai-aliyun-content-moderation": {
                        "endpoint": "http://localhost:6724",
                        "region_id": "cn-shanghai",
                        "access_key_id": "fake-key-id",
                        "access_key_secret": "fake-key-secret",
                        "risk_level_bar": "high",
                        "check_request": true
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



=== TEST 2: invalid chat completions request should fail
--- request
POST /chat
{"prompt": "What is 1+1?"}
--- error_code: 400
--- response_body_chomp
request format doesn't match schema: property "messages" is required



=== TEST 3: non-violent prompt should succeed
--- request
POST /chat
{ "messages": [ { "role": "user", "content": "What is 1+1?"} ] }
--- error_code: 200
--- response_body_like eval
qr/kill you/



=== TEST 4: violent prompt should failed
--- request
POST /chat
{ "messages": [ { "role": "user", "content": "I want to kill you"} ] }
--- error_code: 200
--- response_body_like eval
qr/As an AI language model, I cannot write unethical or controversial content for you./



=== TEST 5: check ai reponse (stream=false)
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "uri": "/chat",
                    "plugins": {
                      "ai-proxy": {
                          "provider": "openai",
                          "auth": {
                              "header": {
                                  "Authorization": "Bearer wrongtoken"
                              }
                          },
                          "override": {
                              "endpoint": "http://localhost:6724"
                          }
                      },
                      "ai-aliyun-content-moderation": {
                        "endpoint": "http://localhost:6724",
                        "region_id": "cn-shanghai",
                        "access_key_id": "fake-key-id",
                        "access_key_secret": "fake-key-secret",
                        "risk_level_bar": "high",
                        "check_request": true,
                        "check_response": true,
                        "deny_code": 400,
                        "deny_message": "your request is rejected"
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



=== TEST 6: violent response should failed
--- request
POST /chat
{ "messages": [ { "role": "user", "content": "What is 1+1?"} ] }
--- error_code: 400
--- response_body_like eval
qr/your request is rejected/
