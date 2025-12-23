#!/usr/bin/env bash

. ./t/cli/common.sh

# Cleanup function to stop docker containers
cleanup_resources() {
    clean_up
    if [ -n "$s3_cont_id" ]; then
        echo "Stopping S3 mock container: $s3_cont_id"
        docker stop "$s3_cont_id" > /dev/null 2>&1
    fi
    if [ -n "$az_cont_id" ]; then
        echo "Stopping Azurite container: $az_cont_id"
        docker stop "$az_cont_id" > /dev/null 2>&1
    fi
    
    # Logic from common.sh clean_up
    if [ $? -gt 0 ]; then
        check_failure
    fi
    make stop || true
    git checkout conf/config.yaml
    git checkout conf/apisix.yaml
}

# Override the trap from common.sh
trap cleanup_resources EXIT

# Helper to wait for a service
wait_for_service() {
    local url=$1
    local name=$2
    local expected_code=${3:-200}
    local max_attempts=10
    local attempt=0
    
    echo "Waiting for $name to be ready..."
    while [ $attempt -le $max_attempts ]; do
        code=$(curl -s -o /dev/null -w "%{http_code}" "$url" || echo "000")
        # Check against expected code. For Azurite root, 400 is common for "Bad Request" meaning server is up.
        if [ "$code" -eq "$expected_code" ] || { [ "$name" == "Azurite" ] && [ "$code" -eq 400 ]; }; then
             echo "$name is ready (status: $code)"
             return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    echo "Timed out waiting for $name"
    exit 1
}

# Helper to verify requests
verify_requests() {
    local desc=$1
    echo "Verifying requests for $desc..."
    
    # first request
    curl -ik -s -o /dev/null -w "%{http_code}" \
      --resolve "test.com:9443:127.0.0.1" "https://test.com:9443/get" \
      -ufoo:bar | grep 200 \
      || (echo "failed: request to route on https endpoint"; exit 1)

    # second request
    curl -s -o /dev/null -w "%{http_code}" -ufoo:bar http://127.0.0.1:9080/get | grep 200 \
    || (echo "failed: request to route created from backup data ($desc) - 2nd attempt"; exit 1)

    # third request will exceed the rate limiting rule and fail
    curl -s -o /dev/null -w "%{http_code}" -ufoo:bar http://127.0.0.1:9080/get | grep 429 \
    || (echo "failed: request to route created from backup data ($desc) - 3rd attempt (should be rate limited)"; exit 1)
    
    etcdctl get /apisix/consumers/foo/credentials/34010989-ce4e-4d61-9493-b54cca8edb31 | grep "XP9G5/payzd2p1MQ7SRe1g==" \
    || (echo "failed: key stored in etcd is not encrypted testing for - ($desc)"; exit 1)
    
    echo "Verification for $desc passed."
}

git checkout conf/config.yaml
git checkout conf/apisix.yaml

# mock CP storing plugins into storage (etcd)
etcdctl put /apisix/plugins '[{"name":"limit-count"},{"name":"basic-auth"}]'

# Start S3 Mock
s3_cont_id=$(docker run -p 6969:9090 -d -e initialBuckets='resource_bucket,config_bucket' -e debug='true' adobe/s3mock:3.8.0)
wait_for_service "http://127.0.0.1:6969/" "S3 Mock" 200 

# Start Azurite
az_cont_id=$(docker run -p 10000:10000 -p 10001:10001 -d mcr.microsoft.com/azure-storage/azurite:3.35.0)
wait_for_service "http://127.0.0.1:10000/" "Azurite" 200

# push dummy data to S3
curl http://127.0.0.1:6969/config_bucket/default -X PUT --upload-file ci/pod/manifests/mock-dp-config-data.json

# push dummy data to Azure
az storage container create \
  --account-name devstoreaccount1 \
  --account-key "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==" \
  --name yaml \
  --blob-endpoint http://127.0.0.1:10000/devstoreaccount1 > /dev/null

az storage container create \
  --account-name devstoreaccount1 \
  --account-key "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==" \
  --name config \
  --blob-endpoint http://127.0.0.1:10000/devstoreaccount1 > /dev/null

az storage blob upload \
  --account-name devstoreaccount1 \
  --account-key "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==" \
  --container-name config \
  --file ci/pod/manifests/mock-dp-config-data.json \
  --name default \
  --blob-endpoint http://127.0.0.1:10000/devstoreaccount1 > /dev/null

# set API7_GATEWAY_GROUP_SHORT_ID such that the prefix matches bucket name for mock-s3
export API7_GATEWAY_GROUP_SHORT_ID="default"
export API7_DP_MANAGER_ENDPOINT_DEBUG="http://localhost:6625"

# Generate config.yaml with both S3 and Azure Blob configured
cat > conf/config.yaml <<EOF
nginx_config:
  error_log_level: info
apisix:
  lua_module_hook: "agent.hook"
  node_listen:
    - 9080
deployment:
  fallback_cp:
    interval: 1
    mode: "write"
    aws_s3:
      access_key: "just-access"
      secret_key: "super-secret"
      resource_bucket: "resource_bucket"
      config_bucket: "config_bucket"
      region: "ap-south-1"
      endpoint: "http://localhost:6969"
    azure_blob:
      account_name: devstoreaccount1
      account_key: "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=="
      resource_container: yaml
      config_container: config
      endpoint: "http://localhost:10000/devstoreaccount1"
EOF

make run
sleep 1

# Create verify resources in APISIX
curl -X PUT 'http://127.0.0.1:9180/apisix/admin/ssls/9d069297-01eb-42b2-bbb9-957d49c75efb' \
-H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' \
-H 'Content-Type: application/json' \
-d '{
    "cert": "-----BEGIN CERTIFICATE-----\nMIIC9jCCAd6gAwIBAgIUYgK2JiHvwnf9XxxCoIAGJiap1f0wDQYJKoZIhvcNAQEL\nBQAwETEPMA0GA1UEAwwGUk9PVENBMCAXDTI0MDYxODA0NDUwNloYDzIxMjQwNTI1\nMDQ0NTA2WjATMREwDwYDVQQDDAh0ZXN0LmNvbTCCASIwDQYJKoZIhvcNAQEBBQAD\nggEPADCCAQoCggEBAMdQPrVinfB7CLWYxWRQqVOwrRf8go9UiSXaQpN8sX2g1ZbS\n/I1FkK98rNivRbAPb2dVcQjR87en1iG5UKgzsburZkpqprn8kBLmzGbd/SNHh7iD\n3OgklFAFK6kdwjE/fNQ81HN/IdONs7jMQ14/yoNnzMd2mayrdLkaXnP8u+yFhhRu\nBAW+pD5GLqt5LGnTK/STKjgO+2FEaXPYWQk+tStXE+cGO3DrAj/Ovx2OoMIEWVTg\nRkVGKWUj4kPDjkqYR7/CtWsf2auHe2o2WXOAe3ssutyuAQdXWPeoXghkPRYKgGVa\n8ARAxYo79V0bFGaxwrk+qrdUS66+Hs+AptCwQ0UCAwEAAaNCMEAwHQYDVR0OBBYE\nFHXwJoWYaKOI9+Ix7LIXd7FxouwTMB8GA1UdIwQYMBaAFLP0CofIycamw4oYFoge\nqywOoMweMA0GCSqGSIb3DQEBCwUAA4IBAQCIP7qBJfCRnPdr9rfR9rEOQIv9bod7\nPz6OgZ8xCAGP5GQKzUJXEBJGvNBNXMGB3vGakMA8tny1tjbyqLCaBlgEK28jgMZI\nqQ/Muh2RQHfniHYXZRVl8MB5f6NePTxUlT6lvWap9yvQJOo9j4vB6sH92RlRLPPy\nkAXPUNNK3omny2o1t87E8yL9NibyMGvf/d6Z4PyCf9vRUCQtrU73HmjWJr3/uWID\ntL1ikrDufgNAPebS92z4ByXQE8+AoUn3LZDEEzyXQ4+YPPVjTP26HDnP1H2uoYn0\nEfHZERKvlIRHR0z8KKJcizkxVe8ew7BmFNd1Ebq3w4aVypuTZXvwfJOD\n-----END CERTIFICATE-----",
    "key": "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",
    "type": "server",
    "snis": ["test.com"]
}'

curl "http://127.0.0.1:9180/apisix/admin/upstreams/1" \
-H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" -X PUT -d '
{
  "type": "roundrobin",
  "nodes": {
    "localhost:8280": 1
  }
}'

curl "http://127.0.0.1:9180/apisix/admin/routes/1" \
-H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" -X PUT -d '
{
  "uri": "/get",
  "plugins": {
    "limit-count": {
      "count": 2,
      "time_window": 10,
      "rejected_code": 429,
      "key_type": "var",
      "key": "remote_addr"
    },
    "basic-auth": {}
  },
  "upstream_id": "1"
}'

curl http://127.0.0.1:9180/apisix/admin/consumers -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" -X PUT -d '
{
    "username": "foo"
}'

curl http://127.0.0.1:9180/apisix/admin/consumers/foo/credentials/34010989-ce4e-4d61-9493-b54cca8edb31 -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" -X PUT -d '
{
  "plugins": {
    "basic-auth": {
      "username": "foo",
      "password": "bar"
    }
  }
}'

# verify that the DP is not listening to incoming requests:
curl http://127.0.0.1:9080/ 2>&1 | grep "Failed to connect" || (echo "Failed to verify that the DP is not listening to incoming requests" && exit 1)

sleep 3
make stop

# TEST 1: Fallback from AWS S3
echo "Testing Fallback from AWS S3..."
cat > conf/config.yaml <<EOF
nginx_config:
  error_log_level: info
apisix:
  lua_module_hook: "agent.hook"
deployment:
  role: data_plane
  role_data_plane:
    config_provider: json
  fallback_cp:
    aws_s3:
      access_key: "just-access"
      secret_key: "super-secret"
      resource_bucket: "resource_bucket"
      config_bucket: "config_bucket"
      region: "ap-south-1"
      endpoint: "http://127.0.0.1:6969"
EOF

make run
verify_requests "AWS S3"
make stop

# TEST 2: Fallback from Azure Blob
echo "Testing Fallback from Azure Blob..."
git checkout conf/config.yaml
git checkout conf/apisix.yaml
echo "" > logs/error.log

cat > conf/config.yaml <<EOF
apisix:
  lua_module_hook: "agent.hook"
deployment:
  role: data_plane
  role_data_plane:
    config_provider: json
  fallback_cp:
    azure_blob:
      account_name: devstoreaccount1
      account_key: "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=="
      resource_container: yaml
      config_container: config
      endpoint: "http://localhost:10000/devstoreaccount1"
EOF

make run
sleep 2
verify_requests "Azure Blob"
