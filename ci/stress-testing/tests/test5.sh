#!/bin/bash

TEST_NAME="Case 5: Single Core, Service + Upstream + Enable Health Checking"
echo "-----------Running test 5: $TEST_NAME ---------------"
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
            "scheme": "https",
            "type": "roundrobin",
            "nodes": [
                    {
                            "host": "127.0.0.1",
                            "port": 8080,
                            "weight": 1
                    },
                    {
                            "host": "127.0.0.1",
                            "port": 8081,
                            "weight": 1
                    },
                    {
                            "host": "127.0.0.1",
                            "port": 8082,
                            "weight": 1
                    },
                    {
                            "host": "127.0.0.1",
                            "port": 8083,
                            "weight": 1
                    },
                    {
                            "host": "127.0.0.1",
                            "port": 8084,
                            "weight": 1
                    }
            ],
            "retries": 2,
            "checks": {
                "active": {
                    "timeout": 5,
                    "http_path": "/status",
                    "host": "foo.com",
                    "healthy": {
                        "interval": 1,
                        "successes": 1
                    },
                    "unhealthy": {
                        "interval": 1,
                        "http_failures": 2
                    },
                    "req_headers": ["User-Agent: curl/7.29.0"]
                },
                "passive": {
                    "healthy": {
                        "http_statuses": [200, 201],
                            "successes": 3
                    },
                    "unhealthy": {
                        "http_statuses": [500],
                        "http_failures": 3,
                        "tcp_failures": 3
                    }
                }
            }
    }
}'

for i in {1..400}; do
  curl "http://127.0.0.1:7080/apisix/admin/routes/$i?gateway_group_id=default" -H 'Content-Type: application/json' -H "X-API-KEY: $TOKEN" -X PUT -d '
    {
        "name": "route_'"$(echo $i)"'",
        "paths": ["/'"$(echo $i)"'"],
        "service_id": "1"
    }'
done
worker_pid=$(ps -ef | grep openresty -A 1 | grep 'nginx: worker process' | head -n 1 | awk '{print $2}')

top -b -n 1 -p $worker_pid >before_cpu_mem.txt
for i in {1..400}; do
  #in the middle check cpu usage
    if [ $i -eq 200 ]; then
        top -b -n 1 -p $worker_pid >during_cpu_mem.txt
    fi
  curl http://localhost:9080/$i
done
sleep 15
top -b -n 1 -p $worker_pid >after_cpu_mem.txt
BEFORE_CPU=$(awk '/%CPU/ {cpu_col=NF-3} /openres/ && cpu_col {print $cpu_col; exit}' before_cpu_mem.txt)
BEFORE_MEM=$(awk '/%MEM/ {mem_col=NF-2} /openres/ && mem_col {print $mem_col; exit}' before_cpu_mem.txt)
AFTER_CPU=$(awk '/%CPU/ {cpu_col=NF-3} /openres/ && cpu_col {print $cpu_col; exit}' after_cpu_mem.txt)
DURING_CPU=$(awk '/%CPU/ {cpu_col=NF-3} /openres/ && cpu_col {print $cpu_col; exit}' during_cpu_mem.txt)
AFTER_MEM=$(awk '/%MEM/ {mem_col=NF-2} /openres/ && mem_col {print $mem_col; exit}' after_cpu_mem.txt)
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
           "BEFORE_MEM": $BEFORE_MEM,
           "AFTER_MEM": $AFTER_MEM}]' "$filepath" > tmp.json

if [ $? -eq 0 ]; then
    mv tmp.json "$filepath"
else
    echo "Error updating JSON file"
    rm tmp.json
fi
#Cleanup
for i in {1..400}; do
  curl "http://127.0.0.1:7080/apisix/admin/routes/$i?gateway_group_id=default" -H "X-API-KEY: $TOKEN" -X DELETE
done
curl "http://127.0.0.1:7080/apisix/admin/services/1?gateway_group_id=default" \
  -X DELETE \
  -H "X-API-KEY: $TOKEN" -u admin:admin
./run.sh stop_dp
