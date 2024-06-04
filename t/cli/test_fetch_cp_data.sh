#!/usr/bin/env bash

. ./t/cli/common.sh

# check etcd while enable auth
git checkout conf/config.yaml

docker run -p 6969:9090 -d -e initialBuckets='bucket' -e debug='true' adobe/s3mock:3.8.0

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
curl http://127.0.0.1:6969/bucket/default -X PUT --upload-file ci/pod/manifests/mock-cp-data.yaml

# wait for sync
sleep 3

# set API7_CONTROL_PLANE_TOKEN such that the prefix matches bucket name for mock-s3
export API7_GATEWAY_GROUP_SHORT_ID="default"

echo '
deployment:
  role: data_plane
  role_data_plane:
    config_provider: yaml
  fallback_cp:
    aws_s3:
      access_key: "just-access"
      secret_key: "super-secret"
      bucket: "bucket"
      region: "ap-south-1"
      endpoint: "http://127.0.0.1:6969"
' > conf/config.yaml

make run

curl http://127.0.0.1:9080/get

curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:9080/get | grep 200 \
|| (echo "failed: request to route created from standalone config from mock s3"; exit 1)
