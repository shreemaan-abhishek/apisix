#!/usr/bin/env bash

. ./t/cli/common.sh

# clean etcd data
etcdctl del / --prefix

# data_plane does not write data to etcd
echo '
deployment:
    role: data_plane
    role_data_plane:
        config_provider: control_plane
        control_plane:
            host:
                - https://127.0.0.1:12379
            prefix: "/apisix"
            timeout: 30
            tls:
                verify: false
' > conf/config.yaml

make run

sleep 1

res=$(etcdctl get / --prefix | wc -l)

if [ ! $res -eq 0 ]; then
    echo "failed: data_plane should not write data to etcd"
    exit 1
fi

echo "passed: data_plane does not write data to etcd"

code=$(curl -o /dev/null -s -w %{http_code} http://127.0.0.1:9080/apisix/admin/routes -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1')
make stop

if [ ! $code -eq 404 ]; then
    echo "failed: data_plane should not enable Admin API"
    exit 1
fi

echo "passed: data_plane should not enable Admin API"

echo '
deployment:
    role: data_plane
    role_data_plane:
        config_provider: control_plane
        control_plane:
            host:
                - https://127.0.0.1:12379
            prefix: "/apisix"
            timeout: 30
' > conf/config.yaml

out=$(make run 2>&1 || true)
make stop
if ! echo "$out" | grep 'failed to load the configuration: https://127.0.0.1:12379: certificate verify failed'; then
    echo "failed: should verify certificate by default"
    exit 1
fi

echo "passed: should verify certificate by default"
