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

  out=$(API7_DP_MANAGER_CERT=$(cat t/certs/mtls_client.crt) API7_DP_MANAGER_KEY=$(cat t/certs/mtls_client.key) make init 2>&1 || echo "ouch")
if echo "$out" | grep "bad certificate"; then
    echo "failed: apisix should not echo \"bad certificate\""
    exit 1
fi

echo "passed: certificate verify success expectedly"

# success: set env API7_DP_MANAGER_CA and verify: false
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

  out=$(API7_DP_MANAGER_CERT=$(cat t/certs/mtls_client.crt) API7_DP_MANAGER_KEY=$(cat t/certs/mtls_client.key) API7_DP_MANAGER_CA=$(cat t/certs/mtls_ca.crt) make init 2>&1 || echo "ouch")
if echo "$out" | grep -E 'bad certificate|certificate verify failed'; then
    echo "failed: apisix should not echo \"bad certificate\" or \"certificate verify failed\""
    exit 1
fi

echo "passed: certificate verify success expectedly"

# failed: should set ssl_trusted_certificate or API7_DP_MANAGER_CA
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

  out=$(API7_DP_MANAGER_CERT=$(cat t/certs/mtls_client.crt) API7_DP_MANAGER_KEY=$(cat t/certs/mtls_client.key) make init 2>&1 || echo "ouch")
if ! echo "$out" | grep -E 'bad certificate|should set ssl_trusted_certificat|certificate verify failed'; then
    echo "failed: apisix should echo \"bad certificate\" or \"should set ssl_trusted_certificat\" or \"certificate verify failed\""
    exit 1
fi

echo "passed: certificate verify success expectedly"

# success: set env API7_DP_MANAGER_CA and verify: true
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

  out=$(API7_DP_MANAGER_CERT=$(cat t/certs/mtls_client.crt) API7_DP_MANAGER_KEY=$(cat t/certs/mtls_client.key) API7_DP_MANAGER_CA=$(cat t/certs/mtls_ca.crt) make run 2>&1 || echo "ouch")
if echo "$out" | grep -E 'bad certificate|should set ssl_trusted_certificat|certificate verify failed'; then
    echo "failed: apisix should not echo \"bad certificate\" or \"should set ssl_trusted_certificat\" or \"certificate verify failed\""
    exit 1
fi

sleep 6

if grep -c "SSL_do_handshake() failed" logs/error.log > /dev/null; then
    echo "failed: failed to mtls handshake"
    exit 1
fi

echo "passed: certificate verify success expectedly"

make stop
sleep 3

# failed: certificate host mismatch
echo '
deployment:
  role: traditional
  role_traditional:
    config_provider: etcd
  etcd:
    host:
      - "https://127.0.0.1:22379"
    prefix: "/apisix"
    tls:
      verify: true
  ' > conf/config.yaml

echo "" > logs/error.log

  out=$(API7_DP_MANAGER_CERT=$(cat t/certs/mtls_client.crt) API7_DP_MANAGER_KEY=$(cat t/certs/mtls_client.key) API7_DP_MANAGER_CA=$(cat t/certs/mtls_ca.crt) make run 2>&1 || echo "ouch")
if echo "$out" | grep -E 'bad certificate|should set ssl_trusted_certificat|certificate host mismatch'; then
    echo "failed: apisix should not echo \"bad certificate\" or \"should set ssl_trusted_certificat\""
    exit 1
fi

sleep 6

if ! grep -c -E "certificate host mismatch|SSL certificate does not match" logs/error.log > /dev/null; then
  echo "failed: error log should contain \"certificate host mismatch\""
  exit 1
fi

make stop
sleep 3

echo "passed: certificate verify success expectedly"

# success: certificate verify success expectedly
echo '
apisix:
  ssl:
    ssl_trusted_certificate: t/certs/mtls_ca.crt
deployment:
  role: traditional
  role_traditional:
    config_provider: etcd
  etcd:
    host:
      - "https://127.0.0.1:22379"
    prefix: "/apisix"
    tls:
      verify: true
  ' > conf/config.yaml

echo "" > logs/error.log

  out=$(API7_DP_MANAGER_CERT=$(cat t/certs/mtls_client.crt) API7_DP_MANAGER_KEY=$(cat t/certs/mtls_client.key) API7_DP_MANAGER_CA=$(cat t/certs/mtls_ca.crt) API7_DP_MANAGER_SNI=admin.apisix.dev make run 2>&1 || echo "ouch")
if echo "$out" | grep -E 'bad certificate|should set ssl_trusted_certificat'; then
    echo "failed: apisix should not echo \"bad certificate\" or \"should set ssl_trusted_certificat\""
    exit 1
fi

if grep -c "SSL_do_handshake() failed" logs/error.log > /dev/null; then
  echo "failed: failed to mtls handshake"
  exit 1
fi

if grep -c "certificate host mismatch" logs/error.log > /dev/null; then
  echo "failed: certificate host mismatch"
  exit 1
fi

echo "passed: certificate verify success expectedly"

#certificate should be stored in files
echo '
deployment:
  role: traditional
  role_traditional:
    config_provider: etcd
  etcd:
    host:
      - "https://127.0.0.1:22379"
    prefix: "/apisix"
    tls:
      verify: true
  ' > conf/config.yaml

echo "" > logs/error.log
  out=$(API7_DP_MANAGER_CERT=$(cat t/certs/mtls_client.crt) API7_DP_MANAGER_KEY=$(cat t/certs/mtls_client.key) make init 2>&1 || echo "ouch")

#check if file exists
if [ ! -f /tmp/api7ee.crt ]; then
  echo "failed: /tmp/api7ee.crt not found"
  exit 1
fi
if [ ! -f /tmp/api7ee.key ]; then
  echo "failed: /tmp/api7ee.key not found"
  exit 1
fi

echo "passed: files created for crt and key successfully"
