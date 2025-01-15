#!/bin/bash

TEST_NAME="Case 8: Single core, service + upstream + prometheus enabled "
echo "-----------Running test 8: $TEST_NAME ---------------"
yq -i '.nginx_config.worker_processes = 1' gateway_conf/config.yaml
yq -i '.plugin_attr.prometheus.export_uri = "/apisix/prometheus/metrics"' gateway_conf/config.yaml
yq -i '.plugin_attr.prometheus.metric_prefix = "apisix_"' gateway_conf/config.yaml
yq -i '.plugin_attr.prometheus.enable_export_server = true' gateway_conf/config.yaml
yq -i '.plugin_attr.prometheus.export_addr.ip = "0.0.0.0"' gateway_conf/config.yaml
yq -i '.plugin_attr.prometheus.export_addr.port = 9091' gateway_conf/config.yaml
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

worker_pid=$(ps -ef | grep openresty -A 1 | grep 'nginx: worker process' | head -n 1 | awk '{print $2}')

top -b -n 1 -p $worker_pid >before_cpu_mem.txt
duration=120

# Get the start time in seconds since the epoch
start_time=$(date +%s)

record_during=0
# Loop until the duration has elapsed
while [ $(($(date +%s) - start_time)) -lt $duration ]; do
  #in the middle check cpu usage
  if  [ $record_during -eq 0 ] && [ $(($(date +%s) - start_time)) -gt $((duration/2)) ]; then
    top -b -n 1 -p $worker_pid > during_cpu_mem.txt
    record_during=1
  fi
  curl -s "http://127.0.0.1:9091/apisix/prometheus/metrics" >/dev/null
done
sleep 15
top -b -n 1 -p $worker_pid >after_cpu_mem.txt

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
   --arg BEFORE_MEM "$BEFORE_MEM" \
   --arg AFTER_MEM "$AFTER_MEM" \
   '. += [{"TEST_NAME": $TEST_NAME,
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
