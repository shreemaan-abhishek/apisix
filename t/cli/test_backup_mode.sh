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
    curl -s -o /dev/null -w "%{http_code}" -ufoo:bar http://127.0.0.1:9080/get | grep 200 \
    || (echo "failed: request to route created from standalone config ($desc) - 1st attempt"; exit 1)

    # second request
    curl -s -o /dev/null -w "%{http_code}" -ufoo:bar http://127.0.0.1:9080/get | grep 200 \
    || (echo "failed: request to route created from standalone config ($desc) - 2nd attempt"; exit 1)

    # third request will exceed the rate limiting rule and fail
    curl -s -o /dev/null -w "%{http_code}" -ufoo:bar http://127.0.0.1:9080/get | grep 429 \
    || (echo "failed: request to route created from standalone config ($desc) - 3rd attempt (should be rate limited)"; exit 1)
    
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
    "username": "foo",
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
