#!/bin/bash
# Set the PS4 environment variable to print the command itself
export PS4='+ $BASH_SOURCE:$LINENO: '

# Enable command tracing
set -x
create_uuid() {
  local uuid=""
  if command -v uuidgen &>/dev/null; then
    uuid=$(uuidgen)
  else
    if [ -f /proc/sys/kernel/random/uuid ]; then
      uuid=$(cat /proc/sys/kernel/random/uuid)
    else
      uuid="fc72beb0-8bee-4f1f-955c-eceb3a287ecb"
    fi
  fi

  echo $uuid | tr '[:upper:]' '[:lower:]' >./gateway_conf/apisix.uid
}

wait_for_service() {
  local service=$1
  local url=$2
  local retry_interval=2
  local retries=0
  local max_retry=30

  echo "Waiting for service $service to be ready..."

  while [ $retries -lt $max_retry ]; do
    if curl -k --output /dev/null --silent --head "$url"; then
      echo "Service $service is ready."
      return 0
    fi

    sleep $retry_interval
    ((retries += 1))
  done

  echo "Timeout: Service $service is not available within the specified retry limit."
  return 1
}

validate_api7_ee() {
  wait_for_service api7-ee-dashboard https://127.0.0.1:7443
  wait_for_service api7-ee-gateway http://127.0.0.1:9080
}

output_listen_address() {
  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    ips=$(ip -4 addr | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127.0.0.1)
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    ips=$(ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1')
  fi

  for ip in $ips; do
    echo "API7-EE Listening: Dashboard(https://$ip:7443), Control Plane Address(http://$ip:7900, https://$ip:7943), Gateway(http://$ip:9080, https://$ip:9443)"
  done
  echo "If you want to access Dashboard with HTTP Endpoint(:7080), you can turn server.listen.disable to false in dashboard_conf/conf.yaml, then restart dashboard container"
}

command=${1:-start_cp}

case $command in
start_cp)
  docker compose -f ./docker-compose-cp.yml up -d #control plane
  sleep 10
  docker container logs stress-testing-api7-ee-dashboard-1
  wait_for_service api7-ee-dp-manager http://127.0.0.1:7900 || {
    echo "Failed to start api7-ee-dp-manager. Exiting."
    exit 1
  }
  docker run -d --network stress-testing_api7 -v ./cert.crt:/etc/ssl/certs/cert.crt -v ./cert.key:/etc/ssl/private/cert.key -v ./ups_nginx.conf:/etc/nginx/nginx.conf --name nginx nginx
  ;;
start_dp)
  gateway_token=$(curl -k https://127.0.0.1:7443/api/gateway_groups/default/instance_token\?only_token\=true --user admin:admin -X POST)
  if [ ! -e "./gateway_conf/apisix.uid" ]; then
    create_uuid
  fi
  docker run -d --name api7-ee-gateway-1 --network=stress-testing_api7 \
    --add-host=host.docker.internal:$(ip route get 1 | awk '{print $7; exit}') \
    -e API7_CONTROL_PLANE_ENDPOINTS='["http://dp-manager:7900"]' \
    -e API7_CONTROL_PLANE_TOKEN=$gateway_token \
    -v $(pwd)/gateway_conf/config.yaml:/usr/local/apisix/conf/config.yaml \
    -v $(pwd)/gateway_conf/apisix.uid:/usr/local/apisix/conf/apisix.uid \
    -p 9080:9080 \
    -p 9443:9443 \
    -p 9091:9091 \
    hkccr.ccs.tencentyun.com/api7-dev/api7-ee-3-gateway:dev
  wait 30
  docker container logs api7-ee-gateway-1
  docker container ps
  curl http://localhost:9080
  
  validate_api7_ee || {
    echo "Failed to validate API7-EE readiness. Exiting."
    exit 1
  }
  echo "API7-EE is ready!"
  output_listen_address
  ;;
stop_dp)
  docker rm --force api7-ee-gateway-1
  ;;
stop_cp)
  docker compose -f ./docker-compose-cp.yml down
  docker container rm -f nginx
  ;;
*)
  echo "Invalid command: $command."
  echo "  start: start the API7-EE."
  echo "  stop: stop the API7-EE."
  exit 1
  ;;
esac
