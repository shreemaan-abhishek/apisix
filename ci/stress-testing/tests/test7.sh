#!/bin/bash

TEST_NAME="Case 7: Two cores, service + upstream + enable prometheus"
echo "-----------Running test 7: $TEST_NAME ---------------"
yq -i '.nginx_config.worker_processes = 2' gateway_conf/config.yaml
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
      "prometheus": {}
  }
}'

curl "http://127.0.0.1:7080/apisix/admin/routes/1?gateway_group_id=default" \
  -H 'Content-Type: application/json' \
  -H "X-API-KEY: $TOKEN" \
  -X PUT -d '
{
  "name": "route_1",
  "paths": ["/hello"],
  "service_id": "1"
}'
pids=$(ps -ef | grep openresty -A 2 | grep 'nginx: worker process' | awk '{print $2}')
worker_pid_1=$(echo "$pids" | awk 'NR==1{print}')
top -b -n 1 -p $worker_pid_1 >before_cpu_mem_1.txt
wrk -c 200 -t 2  -d 60s  -R 40000   http://127.0.0.1:9080/hello >wrk.txt &
sleep 30
top -b -n 1 -p $worker_pid_1 > during_cpu_mem.txt
wait
sleep 15
top -b -n 1 -p $worker_pid_1 >after_cpu_mem_1.txt

QPS=$(cat wrk.txt | grep 'Req/Sec' wrk.txt | awk '{print $2}')
BEFORE_CPU_1=$(awk '/%CPU/ {cpu_col=NF-3} /openres/ && cpu_col {print $cpu_col; exit}' before_cpu_mem_1.txt)
res_kb=$(awk '/RES/ {mem_col=NF-6} /openres/ && mem_col {print $mem_col; exit}' before_cpu_mem_1.txt)
BEFORE_MEM_1=$(echo "scale=2; $res_kb / 1024" | bc)
AFTER_CPU_1=$(awk '/%CPU/ {cpu_col=NF-3} /openres/ && cpu_col {print $cpu_col; exit}' after_cpu_mem_1.txt)
DURING_CPU=$(awk '/%CPU/ {cpu_col=NF-3} /openres/ && cpu_col {print $cpu_col; exit}' during_cpu_mem.txt)
res_kb=$(awk '/RES/ {mem_col=NF-6} /openres/ && mem_col {print $mem_col; exit}' after_cpu_mem_1.txt)
AFTER_MEM_1=$(echo "scale=2; $res_kb / 1024" | bc)
cat $filepath
jq --arg TEST_NAME "$TEST_NAME" \
   --arg BEFORE_CPU_1 "$BEFORE_CPU_1" \
   --arg DURING_CPU "$DURING_CPU" \
   --arg AFTER_CPU_1 "$AFTER_CPU_1" \
   --arg QPS "$QPS" \
   --arg BEFORE_MEM_1 "$BEFORE_MEM_1" \
   --arg AFTER_MEM_1 "$AFTER_MEM_1" \
   '. += [{"TEST_NAME": $TEST_NAME,
           "QPS": $QPS,
           "BEFORE_CPU_1": $BEFORE_CPU_1,
           "DURING_CPU": $DURING_CPU,
           "AFTER_CPU_1": $AFTER_CPU_1,
           "BEFORE_MEM_1(in MB)": $BEFORE_MEM_1,
           "AFTER_MEM_1(in MB)": $AFTER_MEM_1}]' "$filepath" > tmp.json

# Verify jq operation success before replacing the original file
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
