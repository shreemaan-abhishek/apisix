#!/usr/bin/env bash

. ./t/cli/common.sh

exit_if_not_customed_nginx

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

# etcd mTLS verify
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

  out=$(API7_CONTROL_PLANE_CERT=$(cat t/certs/mtls_client.crt) API7_CONTROL_PLANE_KEY=$(cat t/certs/mtls_client.key) make init 2>&1 || echo "ouch")
if echo "$out" | grep "bad certificate"; then
    echo "failed: apisix should not echo \"bad certificate\""
    exit 1
fi

echo "passed: certificate verify success expectedly"
