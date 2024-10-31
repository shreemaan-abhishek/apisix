#!/usr/bin/env bash
. ./t/cli/common.sh

set -ex

make run


send_request() {
  { set +x; } 2>/dev/null # to avoid output from following command to pollute the logs in CI
  exit_code=0
  out=$(curl -s -i http://127.0.0.1:9080/get)
  echo $out | grep "$1" > /dev/null || exit_code=$?
  if [ $exit_code -ne 0 ]; then
    printf "\n\n###########################\n $3 TEST FAILED!!\n"
    printf " $2, but got:\n\n$out \n\n ERROR LOGS:\n\n"
    exit $exit_code
  else
    echo "yes!"
  fi
  set -x
}

perform_test_with_limit_count_configuration() {
  curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:9180/apisix/admin/routes \
  -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' -X PUT -d '{
    "id": "a",
    "uri": "/get",
    "plugins": '"$1"'
    },
    "upstream": {
      "nodes": {
        "127.0.0.1:4901": 1
      },
      "type": "roundrobin"
    }
  }' | grep -e 200 -e 201 || (echo "failed: creating route for test should succeed"; exit 1)

  sleep 3
  sleep $((5-$(date +%s)%5)) # move to start of first time window
  date +%s

  send_request "200 OK" "1 request within first time window should pass" "$2"
  send_request "200 OK" "2 request within first time window should pass" "$2"
  send_request "200 OK" "3 request within first time window should pass" "$2"
  send_request "429 Too Many Requests" "4 request withing first time window should failed" "$2"


  sleep $((5-$(date +%s)%5)) # move to start of next time window
  date +%s

  send_request "200 OK" "first request in second time window should pass" "$2"
  send_request "429 Too Many Requests" "Request exceeding the limit within the sliding window should fail" "$2"

  sleep $((4-$(date +%s)%5)) # release 3 - 1 - (3 * 1/5) = 1.4 request
  send_request "200 OK" "request should pass" "$2"
  send_request "200 OK" "request should pass" "$2"
  send_request "429 Too Many Requests" "Request exceeding the limit within the sliding window should fail" "$2"
}

limit_count_local_config='{
"limit-count-advanced": {
  "count": 3,
  "time_window": 5,
  "rejected_code": 429,
  "key_type": "var",
  "key": "remote_addr",
  "window_type": "sliding"
}'

limit_count_redis_config='{
"limit-count-advanced": {
  "count": 3,
  "time_window": 5,
  "rejected_code": 429,
  "key_type": "var",
  "key": "remote_addr",
  "window_type": "sliding",
  "policy": "redis",
  "redis_host": "127.0.0.1",
  "redis_port": 6379
}'

limit_count_redis_cluster_config='{
"limit-count-advanced": {
  "count": 3,
  "time_window": 5,
  "window_type": "sliding",
  "rejected_code": 429,
  "key": "remote_addr",
  "policy": "redis-cluster",
  "redis_cluster_nodes": [
      "127.0.0.1:5000",
      "127.0.0.1:5002"
  ],
  "redis_cluster_name": "redis-cluster-1"
}'

perform_test_with_limit_count_configuration "$limit_count_local_config" "LIMIT COUNT LOCAL SLIDING WINDOW"
perform_test_with_limit_count_configuration "$limit_count_redis_cluster_config" "LIMIT COUNT REDIS CLUSTER SLIDING WINDOW"
perform_test_with_limit_count_configuration "$limit_count_redis_config" "LIMIT COUNT REDIS SLIDING WINDOW"
