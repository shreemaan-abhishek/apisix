## 描述

`ht-ws-msg-pub` 插件通过 Websocket 协议，实现消息订阅和推送。

消息的订阅需要同时支持通过 Websocket 和 HTTP 接口，因此 Websocket 帧的数据结构我们尽量与 HTTP 请求保持一致。

消息的推送，支持通过指定 Topic 给订阅了该 Topic 的所有客户端连接连接推送消息，也支持通过特殊 Topic 给指定客户端连接推送消息。


## 属性

| 名称           | 类型    | 必选项   | 默认值  | 有效值                                   | 描述                                                                                                                                                                                                                                 |
| ------------- | ------- | ------- | ------ | --------------------------------------- | ----------------------------------------------------------------------------------------------- |
| action        | string | 是       |        | ["sub_put", "sub_add", "sub_delete", "register", "disconnect"]  | 请求类型，决定插件后续逻辑操作流程，sub_put 全量订阅、sub_patch 增量订阅、sub_delete 取消订阅、register 客户端连接注册、disconnect 客户端连接断开 |


## 启用插件

以下示例展示了如何在指定路由上启用 `ht-ws-msg-sub` 插件


握手：
```shell
curl -i http://127.0.0.1:9180/apisix/admin/routes/11 \
-H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' -X PUT -d '
{
    "plugins": {
        "ht-msg-sub": {
            "action": "register",
            "upstream": {
                "nodes": [{
                    "host": "mock-ms1975",
                    "port": 1975,
                    "weight": 1
                }],
                "type": "roundrobin"
            }
        }
    },
    "labels": {
        "superior_id": "1"
    },
    "uri": "/60101/ormp/session/channelRegister"
}'
```

增量订阅：

```shell
curl -i http://127.0.0.1:9180/apisix/admin/routes/12 \
-H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' -X PUT -d '
{
    "plugins": {
        "ht-msg-sub": {
            "action": "sub_add",
            "upstream": {
                "nodes": [{
                    "host": "mock-ms1975",
                    "port": 1975,
                    "weight": 1
                }],
                "type": "roundrobin"
            }
        }
    },
    "labels": {
        "superior_id": "1"
    },
    "uri": "/60150/ormp/subscribe/accountSubscribe"
}'
```

全量订阅：

```shell
curl -i http://127.0.0.1:9180/apisix/admin/routes/13 \
-H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' -X PUT -d '
{
    "plugins": {
        "ht-msg-sub": {
            "action": "sub_put",
            "nodes": [{
                "host": "mock-ms1975",
                "port": 1975,
                "weight": 1
            }],
            "type": "roundrobin"
        }
    },
    "labels": {
        "superior_id": "1"
    },
    "uri": "/60150/ormp/subscribe/syncSubscribe"
}'
```

取消订阅：

```shell
curl -i http://127.0.0.1:9180/apisix/admin/routes/14 \
-H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' -X PUT -d '
{
    "plugins": {
        "ht-msg-sub": {
            "action": "sub_delete",
            "nodes": [{
                "host": "mock-ms1975",
                "port": 1975,
                "weight": 1
            }],
            "type": "roundrobin"
        }
    },
    "labels": {
        "superior_id": "1"
    },
    "uri": "/60150/ormp/subscribe/cancelSubscribe"
}'
```

断开连接：

```shell
curl -i http://127.0.0.1:9180/apisix/admin/routes/15 \
-H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' -X PUT -d '
{
    "plugins": {
        "ht-msg-sub": {
            "action": "disconnect",
            "nodes": [{
                "host": "mock-ms1975",
                "port": 1975,
                "weight": 1
            }],
            "type": "roundrobin"
        }
    },
    "labels": {
        "superior_id": "1"
    },
    "uri": "/60101/ormp/session/channelDisconnect"
}'
```



## 使用示例

### 二、增量订阅

```bash
curl -i http://192.168.10.2:9080/60150/ormp/subscribe/accountSubscribe -X POST \
-H "ts: 132132132" -H "msgId: 01321312" -H "Content-Type: application/json" \
-d '{
    "topics":["hq_100001_129", "hq_100001_123"]
}'
```

### 三、全量订阅

```bash
curl -i http://192.168.10.2:9080/60150/ormp/subscribe/syncSubscribe -X POST \
-H "ts: 132132132" -H "msgId: 01321312" -H "Content-Type: application/json" \
-d '{
    "topics":["hq_100001_129", "hq_100001_123", "hq_100001_131", "hq_100001_133"]
}'
```
