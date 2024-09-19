#!/bin/bash
#sourced in stress-testing.sh
TEST_NAME="Case 1: Single core, Service + upstream, hit route, torture testing 1 min"
echo "-----------Running test1: $TEST_NAME---------------"
yq -i '.nginx_config.worker_processes = 1' gateway_conf/config.yaml
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

worker_pid=$(ps -ef | grep openresty -A 1 | grep 'nginx: worker process' | head -n 1 | awk '{print $2}')
top -b -n 1 -p $worker_pid >before_cpu_mem.txt
wrk -c 200 -t 2  -d 60s  -R 40000    http://127.0.0.1:9080/hello >wrk.txt &
sleep 30
top -b -n 1 -p $worker_pid >during_cpu_mem.txt
wait
sleep 15
cat wrk.txt
top -b -n 1 -p $worker_pid >after_cpu_mem.txt
QPS=$(cat wrk.txt | grep 'Req/Sec' wrk.txt | awk '{print $2}')
BEFORE_CPU=$(awk '/%CPU/ {cpu_col=NF-3} /openres/ && cpu_col {print $cpu_col; exit}' before_cpu_mem.txt)
BEFORE_MEM=$(awk '/%MEM/ {mem_col=NF-2} /openres/ && mem_col {print $mem_col; exit}' before_cpu_mem.txt)
AFTER_CPU=$(awk '/%CPU/ {cpu_col=NF-3} /openres/ && cpu_col {print $cpu_col; exit}' after_cpu_mem.txt)
DURING_CPU=$(awk '/%CPU/ {cpu_col=NF-3} /openres/ && cpu_col {print $cpu_col; exit}' during_cpu_mem.txt)
AFTER_MEM=$(awk '/%MEM/ {mem_col=NF-2} /openres/ && mem_col {print $mem_col; exit}' after_cpu_mem.txt)
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
           "BEFORE_MEM": $BEFORE_MEM, 
           "AFTER_MEM": $AFTER_MEM}]' "$filepath" > tmp.json

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
