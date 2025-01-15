#!/bin/bash
#sourced in stress-testing.sh
TEST_NAME="Case 9: single core, service + upstream + key-auth enabled + consumer 10k"
echo "-----------Running test9: $TEST_NAME---------------"
yq -i '.nginx_config.worker_processes = 1' gateway_conf/config.yaml
yq -i '.api7ee.consumer_proxy.enable = true' dashboard_conf/conf.yaml
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
		"key-auth" : {}
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

# Create 10k consumers
for i in $(seq -w 0 9999); do
  username="test${i}"
  key="auth-${i}"
  curl http://127.0.0.1:9180/apisix/admin/consumers \
    -H 'Content-Type: application/json' \
  	-H "X-API-KEY: $TOKEN" \
    -X PUT -i -d "{
      \"username\": \"${username}\",
      \"plugins\": {
        \"key-auth\": {
          \"key\": \"${key}\"
        }
      }
    }"
done

worker_pid=$(ps -ef | grep openresty -A 1 | grep 'nginx: worker process' | head -n 1 | awk '{print $2}')
top -b -n 1 -p $worker_pid >before_cpu_mem.txt
wrk -s 10k_consumer.lua -c 200 -t 1 -d 60s -R 40000 http://127.0.0.1:9080/hello > wrk.txt &
sleep 30
top -b -n 1 -p $worker_pid >during_cpu_mem.txt
wait
sleep 15
cat wrk.txt
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
   --arg AFTER_CPU "$AFTER_CPU" \
   --arg DURING_CPU "$DURING_CPU" \
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

# Check if the jq command was successful before replacing the original file
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
