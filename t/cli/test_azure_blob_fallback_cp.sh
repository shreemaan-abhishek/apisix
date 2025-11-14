#!/usr/bin/env bash

. ./t/cli/common.sh

# check etcd while enable auth
git checkout conf/config.yaml

cont_id=$(docker run -p 10000:10000 -p 10001:10001 -d mcr.microsoft.com/azure-storage/azurite:3.35.0)

attempt=0
max_attempts=10

while [ $attempt -le $max_attempts ]; do
    status_code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:10000/ || echo "000")

    if [ "$status_code" -eq 200 ] || [ "$status_code" -eq 400 ]; then
        echo "Azurite is ready (status: $status_code)"
        break
    fi

    attempt=$((attempt + 1))
    echo "Waiting for Azurite to start... (attempt: $attempt)"
    sleep 2
done

# upload dummy data
az storage container create \
  --account-name devstoreaccount1 \
  --account-key "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==" \
  --name yaml \
  --blob-endpoint http://127.0.0.1:10000/devstoreaccount1

az storage container create \
  --account-name devstoreaccount1 \
  --account-key "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==" \
  --name config \
  --blob-endpoint http://127.0.0.1:10000/devstoreaccount1

az storage blob upload \
  --account-name devstoreaccount1 \
  --account-key "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==" \
  --container-name config \
  --file ci/pod/manifests/mock-dp-config-data.json \
  --name default \
  --blob-endpoint http://127.0.0.1:10000/devstoreaccount1

az storage blob upload \
  --account-name devstoreaccount1 \
  --account-key "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==" \
  --container-name yaml \
  --file ci/pod/manifests/mock-cp-data.yaml \
  --name default \
  --blob-endpoint http://127.0.0.1:10000/devstoreaccount1

# wait for sync
sleep 3

# set API7_GATEWAY_GROUP_SHORT_ID such that the prefix matches bucket name for mock-s3
export API7_GATEWAY_GROUP_SHORT_ID="default"
export API7_DP_MANAGER_TOKEN="somerandomtoken"


echo '
apisix:
  lua_module_hook: "agent.hook"
deployment:
  role: data_plane
  role_data_plane:
    config_provider: yaml
  fallback_cp:
    azure_blob:
      account_name: devstoreaccount1
      account_key: "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=="
      resource_container: yaml
      config_container: config
      endpoint: "http://localhost:10000/devstoreaccount1"
' > conf/config.yaml

make run

curl -ik -s -o /dev/null -w "%{http_code}" \
--resolve "test.com:9443:127.0.0.1" "https://test.com:9443/get" \
-uba:secure -s | grep 200 \
|| (echo "failed: request to route created from standalone config from mock s3"; exit 1)

curl -s -o /dev/null -w "%{http_code}" -uba:secure http://127.0.0.1:9080/get -s | grep 200 \
|| (echo "failed: request to route created from standalone config from mock s3"; exit 1) #second request

# third request will exceed the rate limitng rule and fail
curl -s -o /dev/null -w "%{http_code}" -uba:secure http://127.0.0.1:9080/get -s | grep 504 \
|| (echo "failed: request to route created from standalone config from mock s3"; exit 1)

curl http://127.0.0.1:9080/ip -s | grep "this is custom_plugin custom body" \
|| (echo "failed: request to route with custom_plugin"; exit 1)

exit_code=1 # non zero exit code
grep -c "has no healthy etcd endpoint available" logs/error.log > /dev/null || exit_code=$?
if [ $exit_code -eq 0 ]; then
  echo "failed: should not contain etcd endpoints unavailable error"
  exit 1
fi

docker rm -f $cont_id
