#!/bin/bash
# AI Plugin related test

TEST_NAME="Case 10: Single core, Enable plugin: AI Proxy + AI Rate Limiting  + Prometheus + stream=false"
echo "-----------Running test : $TEST_NAME ---------------"
yq -i '.nginx_config.worker_processes = 1' gateway_conf/config.yaml
# start sse server

./run.sh start_dp
#Create Route and service
curl "http://127.0.0.1:7080/apisix/admin/services/1?gateway_group_id=default" \
  -H 'Content-Type: application/json' \
  -H "X-API-KEY: $TOKEN" \
  -X PUT -d '
{
  "name": "test",
  "upstream": {
      "type": "roundrobin",
      "nodes": [
          {
              "host": "nginx",
              "port": 80,
              "weight": 1
          }
      ]
  },
  "plugins": {
      "prometheus": {},
      "ai-proxy": {
          "provider": "openai",
          "auth": {
              "header": {
                  "Authorization": "Bearer token"
              }
          },
          "options": {
              "model": "gpt-35-turbo-instruct",
              "max_tokens": 512,
              "temperature": 1.0,
              "stream": false
          },
          "override": {
              "endpoint": "http://llm_server:7737/v1/chat/completions"
          },
          "ssl_verify": false
      },
      "ai-rate-limiting": {
        "limit": 30,
        "time_window": 60,
        "rejected_code": 403,
        "rejected_msg": "rate limit exceeded"
      }
  }
}'

curl "http://127.0.0.1:7080/apisix/admin/routes/1?gateway_group_id=default" \
  -H 'Content-Type: application/json' \
  -H "X-API-KEY: $TOKEN" \
  -X PUT -d '
{
  "name": "route_1",
  "paths": ["/ai"],
  "service_id": "1"
}'

worker_pid=$(ps -ef | grep openresty -A 1 | grep 'nginx: worker process' | head -n 1 | awk '{print $2}')
top -b -n 1 -p $worker_pid >before_cpu_mem.txt

# POST request to AI Proxy endpoint with rate limiting
wrk -c 200 -t 2 -d 60s -R 5000 -s ./tests/post-test-non-stream.lua http://127.0.0.1:9080 > wrk.txt &
sleep 30
top -b -n 1 -p $worker_pid > during_cpu_mem.txt
sleep 40
top -b -n 1 -p $worker_pid >after_cpu_mem.txt

QPS=$(cat wrk.txt | grep 'Req/Sec' wrk.txt | awk '{print $2}')
BEFORE_CPU=$(awk '/%CPU/ {cpu_col=NF-3} /openres/ && cpu_col {print $cpu_col; exit}' before_cpu_mem.txt)
res_kb=$(awk '/RES/ {mem_col=NF-6} /openres/ && mem_col {print $mem_col; exit}' before_cpu_mem.txt)
BEFORE_MEM=$(echo "scale=2; $res_kb / 1024" | bc)
AFTER_CPU=$(awk '/%CPU/ {cpu_col=NF-3} /openres/ && cpu_col {print $cpu_col; exit}' after_cpu_mem.txt)
DURING_CPU=$(awk '/%CPU/ {cpu_col=NF-3} /openres/ && cpu_col {print $cpu_col; exit}' during_cpu_mem.txt)
res_kb=$(awk '/RES/ {mem_col=NF-6} /openres/ && mem_col {print $mem_col; exit}' after_cpu_mem.txt)
AFTER_MEM=$(echo "scale=2; $res_kb / 1024" | bc)
jq --arg TEST_NAME "$TEST_NAME" \
   --arg BEFORE_CPU "$BEFORE_CPU" \
   --arg DURING_CPU "$DURING_CPU" \
   --arg AFTER_CPU "$AFTER_CPU" \
   --arg QPS "$QPS" \
   --arg BEFORE_MEM "$BEFORE_MEM" \
   --arg AFTER_MEM "$AFTER_MEM" \
   '. += [{"TEST_NAME": $TEST_NAME, 
           "QPS": $QPS, 
           "BEFORE_CPU": $BEFORE_CPU, 
           "DURING_CPU": $DURING_CPU, 
           "AFTER_CPU": $AFTER_CPU, 
           "BEFORE_MEM(in MB)": $BEFORE_MEM, 
           "AFTER_MEM(in MB)": $AFTER_MEM}]' "$filepath" > tmp.json

if [ $? -eq 0 ]; then
    mv tmp.json "$filepath"
else
    echo "Error updating JSON file"
    rm tmp.json
fi
#Cleanup
curl "http://127.0.0.1:7080/apisix/admin/routes/1?gateway_group_id=default" \
  -X DELETE \
  -H "X-API-KEY: $TOKEN" -u admin:admin
curl "http://127.0.0.1:7080/apisix/admin/services/1?gateway_group_id=default" \
  -X DELETE \
  -H "X-API-KEY: $TOKEN" -u admin:admin
./run.sh stop_dp
