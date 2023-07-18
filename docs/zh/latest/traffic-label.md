---
title: traffic-label
keywords:
  - APISIX
  - Plugin
  - traffic-label
  - 染色
  - 泳道
description: 本文介绍了关于 Apache APISIX `traffic-label` 插件的基本信息及使用方法。
---

<!--
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
-->

## 描述

`traffic-label` 插件功能与 [workflow](https://apisix.apache.org/docs/apisix/next/plugins/workflow/) 插件类似，支持设置多个匹配规则，并对命中不同规则的请求分别进行改写。不同点是 `traffic-label` 插件支持对改写动作设置权重，流量会按照设置的权重就行分发。

## 属性

| 名称          | 类型   | 必选项  | 默认值                    | 有效值                                                                                                                                            | 描述 |
| ------------- | ------ | ------ | ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------- | ------------- |
| rules | array[object] | 是 |  |                                                                                                                            | 由一个 `match` 和一个 `actions` array 组成，其中 `match` 是匹配条件，`actions` 是要执行的动作，包含一个或多个动作 |
| rules.match | array[array] | 是 |  |                                                                                                                            | 由一个或多个 `{var, operator, val}` 元素组成的列表。例如`{"arg_name", "==", "price"}`，表示当前请求参数 `name` 的值为 `price`。其中，`var` 支持内置变量 （Nginx 变量和 APISIX 变量）；Operator 支持 [lua-resty-expr logical operators](https://github.com/api7/lua-resty-expr#operator-list) 。 |
| rules.actions | array[object] | 是    |                   |                                                                                                                | 当 `match` 成功匹配时要执行的 `actions`。目前，`actions` 中只支持一个动作 `set_headers` |
| rules.actions.set_headers| object | 否 |  | | 改写请求头，如果有同名的会覆盖，没有则会添加。格式为 `{"name": "value", ...}`。这个值能够以 `$var` 的格式包含 NGINX 变量，比如 `$remote_addr $balancer_ip`。|
| rules.actions.weight | number | 否    |          1         |                 正整数                                                                                               | 当 `match` 成功匹配后有多少流量会执行当前的 action，例如 action1 的 weight 是 3， action2 的 weight 是 7，则有30%的流量会执行 action1，70%的流量会执行 action2。|

:::note

- 在 `rules` 中，按照 `rules` 的数组下标顺序依次匹配 `match`，如果 `case` 匹配成功，则直接执行对应的 `actions`，后续的 `rules` 不再进行匹配，参考 [多个匹配规则](#多个匹配规则)

- 如果在 `actions` 中只设置 `weight`，不设置要执行的动作，表示有多少流量在匹配成功后不进行任何操作，参考 [动作的权重](#动作的权重)。

:::

## 启用插件

以下示例展示了如何在路由中启用 `traffic-label` 插件：

### 添加请求头

```shell
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
-H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' -X PUT -d '
{
    "uri":"/headers",
    "plugins":{
        "traffic-label": {
            "rules": [
                {
                    "match": [
                        ["uri", "==", "/headers"]
                    ],
                    "actions": [
                        {
                            "set_headers": {
                                "X-Server-Id": 100
                            }
                        }
                    ]
                }
            ]
        }
    },
    "upstream":{
        "type":"roundrobin",
        "nodes":{
            "httpbin.org:80":1
        }
    }
}'
```

如果我们请求 `/headers`，则 `X-Server-Id: 100` 会被添加到请求头中。

```shell
curl http://127.0.0.1:9080/headers

X-Server-Id: 100
```

### 匹配条件中的逻辑关系 AND

```shell
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
-H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' -X PUT -d '
{
    "uri":"/headers",
    "plugins":{
        "traffic-label": {
            "rules": [
                {
                    "match": [
                        ["uri", "==", "/headers"],
                        ["arg_version", "==", "v1"]
                    ],
                    "actions": [
                        {
                            "set_headers": {
                                "X-Server-Id": 100
                            }
                        }
                    ]
                }
            ]
        }
    },
    "upstream":{
        "type":"roundrobin",
        "nodes":{
            "httpbin.org:80":1
        }
    }
}'
```
如果我们请求 `/headers`，则 `X-Server-Id: 100` 不会被添加到请求头中，因为此时 `match` 中的逻辑关系为 `AND`，具体请参考 [lua-resty-expr](https://github.com/api7/lua-resty-expr#operator-list)。

```shell
curl http://127.0.0.1:9080/headers
```

### 匹配条件中的逻辑关系 OR

```shell
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
-H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' -X PUT -d '
{
    "uri":"/headers",
    "plugins":{
        "traffic-label": {
            "rules": [
                {
                    "match": [
                        "OR",
                        ["arg_version", "==", "v1"],
                        ["uri", "==", "/headers"]
                    ],
                    "actions": [
                        {
                            "set_headers": {
                                "X-Server-Id": 100
                            }
                        }
                    ]
                }
            ]
        }
    },
    "upstream":{
        "type":"roundrobin",
        "nodes":{
            "httpbin.org:80":1
        }
    }
}'
```
如果我们请求 `/headers`，则 `X-Server-Id: 100` 会被添加到请求头中，因为此时 `match` 中的逻辑关系为 `OR`，具体请参考 [lua-resty-expr](https://github.com/api7/lua-resty-expr#operator-list)。

```shell
curl http://127.0.0.1:9080/headers

X-Server-Id: 100
```

### 动作的权重

```shell
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
-H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' -X PUT -d '
{
    "uri":"/headers",
    "plugins":{
        "traffic-label": {
            "rules": [
                {
                    "match": [
                        ["uri", "==", "/headers"]
                    ],
                    "actions": [
                        {
                            "set_headers": {
                                "X-Server-Id": 100
                            },
                            "weight": 3
                        },
                        {
                            "set_headers": {
                                "X-API-Version": "v2"
                            },
                            "weight": 2
                        },
                        {
                            "weight": 5
                        }
                    ]
                }
            ]
        }
    },
    "upstream":{
        "type":"roundrobin",
        "nodes":{
            "httpbin.org:80":1
        }
    }
}'
```

每个 action 被执行次数的占比为当前 action 的权重与总权重的比值，总的权重为 actions 下所有 action 权重的累加：3 + 2 + 5 = 10，例如如果我们多次请求，则 3 / 10 = 30% 的请求会被增加 `X-Server-Id: 100` 请求头，2 / 10 = 20% 的请求会被增加 `X-API-Version: v2` 请求头，5 / 10 = 50% 的请求不会有任何操作。

### 多个匹配规则

```shell
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
-H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' -X PUT -d '
{
    "uri":"/headers",
    "plugins":{
        "traffic-label": {
            "rules": [
                {
                    "match": [
                        ["arg_version", "==", "v1"]
                    ],
                    "actions": [
                        {
                            "set_headers": {
                                "X-Server-Id": 100
                            }
                        }
                    ]
                },
                {
                    "match": [
                        ["arg_version", "==", "v2"]
                    ],
                    "actions": [
                        {
                            "set_headers": {
                                "X-Server-Id": 200
                            }
                        }
                    ]
                }
            ]
        }
    },
    "upstream":{
        "type":"roundrobin",
        "nodes":{
            "httpbin.org:80":1
        }
    }
}'
```

如果我们请求 `/headers?version=v1`，则 `X-Server-Id: 100` 会被添加到请求头中。

```shell
curl http://127.0.0.1:9080/headers?version=v1

X-Server-Id: 100
```

如果我们请求 `/headers?version=v2`，则 `X-Server-Id: 200` 会被添加到请求头中。

```shell
curl http://127.0.0.1:9080/headers?version=v2

X-Server-Id: 200
```

## 删除插件

当你需要删除 `traffic-label` 插件时，可以通过以下命令删除相应的 JSON 配置，APISIX 将会自动重新加载相关配置，无需重启服务：

```shell
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
-H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' -X PUT -d '
{
    "uri":"/headers/*",
    "upstream": {
        "type": "roundrobin",
        "nodes": {
            "httpbin.org:80": 1
        }
    }
}'
```
