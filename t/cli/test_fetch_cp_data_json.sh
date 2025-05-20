#!/usr/bin/env bash

. ./t/cli/common.sh

# check etcd while enable auth
git checkout conf/config.yaml

cont_id=$(docker run -p 6969:9090 -d -e initialBuckets='resource_bucket,config_bucket' -e debug='true' adobe/s3mock:3.8.0)

attempt=0
while [ $attempt -le 10 ]; do
    if ! curl -s --head --fail http://127.0.0.1:6969/ > /dev/null 2>&1; then
        attempt=$((attempt + 1))
        sleep 1
    else
        break
    fi
done

# push dummy data
curl http://127.0.0.1:6969/resource_bucket/default -X PUT --upload-file ci/pod/manifests/mock-cp-data.json
curl http://127.0.0.1:6969/config_bucket/default -X PUT --upload-file ci/pod/manifests/mock-dp-config-data.json

# wait for sync
sleep 3

# set API7_GATEWAY_GROUP_SHORT_ID such that the prefix matches bucket name for mock-s3
export API7_GATEWAY_GROUP_SHORT_ID="default"
export API7_CONTROL_PLANE_TOKEN="somerandomtoken"


echo '
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
' > conf/config.yaml

make run

curl -ik -s -o /dev/null -w "%{http_code}" \
--resolve "test.com:9443:127.0.0.1" "https://test.com:9443/get" \
-uba:secure | grep 200 \
|| (echo "failed: request to route created from standalone config from mock s3"; exit 1)

curl -s -o /dev/null -w "%{http_code}" -uba:secure http://127.0.0.1:9080/get | grep 200 \
|| (echo "failed: request to route created from standalone config from mock s3"; exit 1) #second request

# third request will exceed the rate limitng rule and fail
curl -s -o /dev/null -w "%{http_code}" -uba:secure http://127.0.0.1:9080/get | grep 504 \
|| (echo "failed: request to route created from standalone config from mock s3"; exit 1)

curl http://127.0.0.1:9080/ip | grep "this is custom_plugin custom body" \
|| (echo "failed: request to route with custom_plugin"; exit 1)

exit_code=1 # non zero exit code
grep -c "has no healthy etcd endpoint available" logs/error.log > /dev/null || exit_code=$?
if [ $exit_code -eq 0 ]; then
  echo "failed: should not contain etcd endpoints unavailable error"
  exit 1
fi

docker rm -f $cont_id
