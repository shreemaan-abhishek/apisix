## 描述

`graphql-proxy-cache` 插件提供缓存 GraphQL 请求响应数据的能力，它可以和其他插件一起使用。该插件支持基于磁盘和内存的缓存。支持对 GET 和 POST 两种方式的 GraphQL 请求进行缓存。

目前，缓存 key 采用如下方式生成：

```
key = md5(plugin_conf_version, body)
```

其中：

- plugin_conf_version：plugin_conf_version 为 `graphql-proxy-cache` 插件配置的版本号。
- body：GraphQL 请求的查询字符串。对于 GET 请求，它是请求的参数；对于 POST 请求，它是请求体。

如果 GraphQL 请求的 query 中包含 mutation 操作，则不会对请求响应进行缓存。

## 属性

| 名称               | 类型           | 必选项 | 默认值                    | 有效值                                                                          | 描述                                                                                                                               |
| ------------------ | -------------- | ------ | ------------------------- | ------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| cache_strategy     | string         | 否   | disk                      | ["disk","memory"]                                                               | 缓存策略，指定缓存数据存储在磁盘还是内存中。 |
| cache_zone         | string         | 否   | disk_cache_one     |                                                                                 | 指定使用哪个缓存区域，不同的缓存区域可以配置不同的路径，在 `conf/config.yaml` 文件中可以预定义使用的缓存区域。如果指定的缓存区域与配置文件中预定义的缓存区域不一致，那么缓存无效。   |
| cache_ttl          | integer        | 否   | 300 秒                    |                                                                                 | 使用 memory 缓存策略时的缓存时间。    |

:::note 注意

- 对于基于磁盘的缓存，不能动态配置缓存的过期时间，只能通过后端服务响应头 `Expires` 或 `Cache-Control` 来设置过期时间，当后端响应头中没有 `Expires` 或 `Cache-Control` 时，默认缓存时间为 10 秒钟

:::

## 启用插件

该插件的缓存能力复用了 `proxy-cache` 插件，因此你可以在 APISIX 配置文件 `conf/config.yaml` 中添加你的缓存配置，示例如下：

```yaml title="conf/config.yaml"
proxy_cache:                       # 代理缓存配置
    cache_ttl: 10s                 # 如果上游未指定缓存时间，则为默认缓存时间
    zones:                         # 缓存的参数
    - name: disk_cache_one         # 缓存名称（缓存区域），管理员可以通过 admin api 中的 cache_zone 字段指定要使用的缓存区域
      memory_size: 50m             # 共享内存的大小，用于存储缓存索引
      disk_size: 1G                # 磁盘大小，用于存储缓存数据
      disk_path: "/tmp/disk_cache_one" # 存储缓存数据的路径
      cache_levels: "1:2"          # 缓存的层次结构级别
```

以下示例展示了如何在指定路由上启用 `graphql-proxy-cache` 插件，`cache_zone` 字段默认设置为 `disk_cache_one`：

```shell
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
-H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' -X PUT -d '
{
    "plugins": {
        "graphql-proxy-cache": {
        }
    },
    "upstream": {
        "nodes": {
            "127.0.0.1:8080": 1
        },
        "type": "roundrobin"
    },
    "uri": "/graphql"
}'
```

## 启动 GraphQL 服务

为了方便测试，可以使用 docker 命令快速启动一个简单的 GraphQL 服务：

```
docker run -d --name graphql-demo --rm -p 8080:8080 npalm/graphql-java-demo
```

## 测试插件
### 缓存

按上述配置启用插件后，使用 `curl` 命令请求该路由：

```shell
curl http://127.0.0.1:9080/graphql -H"Content-Type: application/json" -d '
{
    "query": "query($name:String!){persons(filter:{name:$name}){name\nblog\ngithubAccount}}",
    "variables": "{\"name\": \"Niek\"}"
}'
```

如果返回 `200` HTTP 状态码，并且响应头中包含 `Apisix-Cache-Status`字段，则表示该插件已启用：

```shell
HTTP/1.1 200 OK
···
Apisix-Cache-Status: MISS
Apisix-Cache-Key: c6b8f91705a50d2d1972b1b232b3174f

{"data":{"persons":[{"name":"Niek","blog":"https://040code.github.io","githubAccount":"npalm"}]}}
```

如果你是第一次请求该路由，数据未缓存，那么 `Apisix-Cache-Status` 字段应为 `MISS`。此时再次请求该路由：

```shell
curl http://127.0.0.1:9080/graphql -H"Content-Type: application/json" -d '
{
    "query": "query($name:String!){persons(filter:{name:$name}){name\nblog\ngithubAccount}}",
    "variables": "{\"name\": \"Niek\"}"
}'
```

如果返回的响应头中 `Apisix-Cache-Status` 字段变为 `HIT`，则表示数据已被缓存，插件生效：

```shell
HTTP/1.1 200 OK
···
Apisix-Cache-Status: HIT
Apisix-Cache-Key: c6b8f91705a50d2d1972b1b232b3174f

{"data":{"persons":[{"name":"Niek","blog":"https://040code.github.io","githubAccount":"npalm"}]}}
```

### 删除缓存

`graphql-proxy-cache` 插件会增加 `/apisix/plugin/graphql-proxy-cache/:strategy/:route_id/:cache_key` 接口用于删除缓存数据，请求方法为 `PURGE`。 其中：

- strategy: 缓存数据存储的位置，对应 `cache_strategy` 配置，可设置为 `disk` 或 `memeory`
- route_id: 路由 id
- cache_key: 缓存 key，`graphql-proxy-cache` 插件会将缓存 key 在响应头中，字段名称为：APISIX-Cache-Key

如果要删除上述缓存数据，可以按照下面的步骤：

通过 public-api 插件暴露删除缓存的接口：

```shell
curl http://127.0.0.1:9180/apisix/admin/routes/graphql-cache-purge \
-H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' -X PUT -d '
{
    "plugins": {
        "public-api": {}
    },
    "uri": "/apisix/plugin/graphql-proxy-cache/*"
}'
```

通过删除缓存的接口，删除缓存数据：

```shell
curl http://127.0.0.1:9080/apisix/plugin/graphql-proxy-cache/disk/1/c6b8f91705a50d2d1972b1b232b3174f -XPURGE
```

## 禁用插件

当你需要禁用该插件时，可以通过以下命令删除相应的 JSON 配置，APISIX 将会自动重新加载相关配置，无需重启服务：

```shell
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
-H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' -X PUT -d '
{
    "uri": "/graphql",
    "plugins": {},
    "upstream": {
        "type": "roundrobin",
        "nodes": {
            "127.0.0.1:8080": 1
        }
    }
}'
```
