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

# success: set env API7_CONTROL_PLANE_CA and verify: false
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

  out=$(API7_CONTROL_PLANE_CERT=$(cat t/certs/mtls_client.crt) API7_CONTROL_PLANE_KEY=$(cat t/certs/mtls_client.key) API7_CONTROL_PLANE_CA=$(cat t/certs/mtls_ca.crt) make init 2>&1 || echo "ouch")
if echo "$out" | grep "bad certificate"; then
    echo "failed: apisix should not echo \"bad certificate\" or \"should set ssl_trusted_certificat\""
    exit 1
fi

echo "passed: certificate verify success expectedly"

# failed: should set ssl_trusted_certificate or API7_CONTROL_PLANE_CA
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
      verify: true
  ' > conf/config.yaml

  out=$(API7_CONTROL_PLANE_CERT=$(cat t/certs/mtls_client.crt) API7_CONTROL_PLANE_KEY=$(cat t/certs/mtls_client.key) make init 2>&1 || echo "ouch")
if ! echo "$out" | grep -E 'bad certificate|should set ssl_trusted_certificat'; then
    echo "failed: apisix should echo \"bad certificate\" or \"should set ssl_trusted_certificat\""
    exit 1
fi

echo "passed: certificate verify success expectedly"

# success: set env API7_CONTROL_PLANE_CA and verify: true
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
      verify: true
  ' > conf/config.yaml

echo "" > logs/error.log

#
  out=$(API7_CONTROL_PLANE_CERT=$(cat t/certs/mtls_client.crt) API7_CONTROL_PLANE_KEY=$(cat t/certs/mtls_client.key) API7_CONTROL_PLANE_CA=$(cat t/certs/mtls_ca.crt) make run 2>&1 || echo "ouch")
if echo "$out" | grep -E 'bad certificate|should set ssl_trusted_certificat'; then
    echo "failed: apisix should not echo \"bad certificate\" or \"should set ssl_trusted_certificat\""
    exit 1
fi

sleep 6

if grep -c "SSL_do_handshake() failed" logs/error.log > /dev/null; then
    echo "failed: failed to mtls handshake"
    exit 1
fi

echo "passed: certificate verify success expectedly"
