#!/usr/bin/env bash

. ./t/cli/common.sh

# HTTP
echo '
deployment:
    role: traditional
    role_traditional:
        config_provider: etcd
    etcd:
        prefix: "/apisix"
        host:
            - http://127.0.0.1:2379
' > conf/config.yaml

make run
sleep 1

code=$(curl -o /dev/null -s -w %{http_code} http://127.0.0.1:9180/apisix/admin/routes -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1')
make stop

if [ ! $code -eq 200 ]; then
    echo "failed: could not connect to etcd with http enabled"
    exit 1
fi

# Both HTTP and Stream
echo '
apisix:
    enable_admin: true
    stream_proxy:
        tcp:
            - addr: 9100
deployment:
    role: traditional
    role_traditional:
        config_provider: etcd
    etcd:
        prefix: "/apisix"
        host:
            - http://127.0.0.1:2379
' > conf/config.yaml

make run
sleep 1

code=$(curl -o /dev/null -s -w %{http_code} http://127.0.0.1:9180/apisix/admin/routes -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1')
make stop

if [ ! $code -eq 200 ]; then
    echo "failed: could not connect to etcd with http & stream enabled"
    exit 1
fi

# Stream
echo '
apisix:
    enable_admin: false
    stream_proxy:
        tcp:
            - addr: 9100
deployment:
    role: traditional
    role_traditional:
        config_provider: etcd
    etcd:
        prefix: "/apisix"
        host:
            - http://127.0.0.1:2379
' > conf/config.yaml

make run
sleep 1
make stop

if grep '\[error\]' logs/error.log; then
    echo "failed: could not connect to etcd with stream enabled"
    exit 1
fi

echo "passed: could connect to etcd"

echo '
deployment:
    role: traditional
    role_traditional:
        config_provider: etcd
    etcd:
        host:
            - "https://admin.apisix.dev:22379"
        prefix: "/apisix"
        tls:
            verify: false
  ' > conf/config.yaml

out=$(make init 2>&1 || echo "ouch")
if ! echo "$out" | grep "bad certificate"; then
    echo "failed: apisix should echo \"bad certificate\""
    exit 1
fi

echo "passed: certificate verify fail expectedly"
