#!/usr/bin/env bash

. ./t/cli/common.sh

# The 'admin.apisix.dev' is injected by ci/common.sh@set_coredns
echo '
apisix:
    enable_admin: false
deployment:
    role: control_plane
    role_control_plane:
        config_provider: etcd
    etcd:
        prefix: "/apisix"
        host:
            - http://127.0.0.1:2379
' > conf/config.yaml

make run
sleep 1

code=$(curl -o /dev/null -s -w %{http_code} http://127.0.0.1:9180/apisix/admin/routes -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1')

if [ ! $code -eq 200 ]; then
    echo "failed: control_plane should enable Admin API"
    exit 1
fi

echo "passed: control_plane should enable Admin API"

curl -i http://127.0.0.1:9180/apisix/admin/routes/1 -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' -X PUT -d '
{
    "upstream": {
        "nodes": {
            "httpbin.org:80": 1
        },
        "type": "roundrobin"
    },
    "uri": "/*"
}'

code=$(curl -o /dev/null -s -w %{http_code} http://127.0.0.1:9180/c -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1')
make stop
if [ ! $code -eq 404 ]; then
    echo "failed: should disable request proxy"
    exit 1
fi

echo "passed: should disable request proxy"
