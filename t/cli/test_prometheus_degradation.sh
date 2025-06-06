#!/usr/bin/env bash

#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

. ./t/cli/common.sh

# configure a smaller shared memory to make it easier to be used up
echo '
deployment:
  role: data_plane
  role_data_plane:
    config_provider: yaml
nginx_config:
  meta:
    lua_shared_dict:
      prometheus-metrics: 1m
plugin_attr:
  prometheus:
    allow_degradation: true
    degradation_pause_steps: [ 5 ]
' > conf/config.yaml

echo > conf/apisix.yaml

echo 'routes:' >> conf/apisix.yaml
for i in {1..50}; do
    echo '
  - uri: "/test/'$i'"
    plugins:
        prometheus: {}
' >> conf/apisix.yaml
done

echo '
#END
' >> conf/apisix.yaml

make run
sleep 1

echo 'send request to /test/1'
code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:9080/test/1)
# we don't configure upstream for those routes, so the response code should be 503
if [ "$code" -ne 503 ]; then
    echo "failed: expected status code 503, got $code"
    exit 1
fi

sleep 1

echo 'check http_status metric for /test/1'
if ! curl -s http://127.0.0.1:9091/apisix/prometheus/metrics | grep 'http_status.*code="503".*matched_uri="/test/1"' > /dev/null; then
    echo "failed: metrics should contain /test/1 metric"
    exit 1
fi

echo 'check prometheus_disable metric'
if ! curl -s http://127.0.0.1:9091/apisix/prometheus/metrics | grep 'prometheus_disable{.*0$' > /dev/null; then
    echo "failed: prometheus_disable metric should be set to 0"
    exit 1
fi

echo 'send requests to /test/1-50'
for i in {1..50}; do
    curl -s http://127.0.0.1:9080/test/$i -o /dev/null
done

sleep 1

echo 'check error log for degradation'
if ! grep "Shared dictionary used for prometheus metrics is full.*Disabling for 5 seconds" logs/error.log > /dev/null; then
  echo "failed: error log should contain \"Shared dictionary used for prometheus metrics is full\""
  exit 1
fi

echo 'wait for degradation to take effect'
sleep 2

echo 'prometheus_disable metric should be updated'
if ! curl -s http://127.0.0.1:9091/apisix/prometheus/metrics | grep 'prometheus_disable{.*1$' > /dev/null; then
    echo "failed: prometheus_disable metric should be set to 1"
    exit 1
fi

echo 'all http_status metrics should be cleared'
if curl -s http://127.0.0.1:9091/apisix/prometheus/metrics | grep 'http_status{' > /dev/null; then
    echo "failed: http_status metrics should be cleared during degradation"
    exit 1
fi

echo 'reload APISIX during degradation'
make reload
sleep 1

echo 'check prometheus_disable metric after reload'
if ! curl -s http://127.0.0.1:9091/apisix/prometheus/metrics | grep 'prometheus_disable{.*0$' > /dev/null; then
    echo "failed: prometheus_disable metric should be reset to 0 after reload"
    exit 1
fi

make stop

echo "pass: prometheus degradation test"
