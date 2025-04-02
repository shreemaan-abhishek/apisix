#!/bin/bash
set -x
testname=all
filepath=output.json
echo "starting server"
cd ../..
pwd
ls linux-common-runnner.sh
./ci/utils/linux-common-runnner.sh start_sse_server_example
if [[ $(lsof -i :7737 -t) == "" ]]; then
  echo "Failed to start server"
  exit 1
fi
echo "Server started successfully on port 7737"
cd ci/stress-testing
# Parse flags
while getopts "t:f:" opt; do
  case $opt in
  t) testname="$OPTARG" ;;
  f) filepath="$OPTARG" ;;
  *)
    echo "Usage: $0 -t <testID> -f <filepath>"
    echo "Use $0 list to see available tests"
    exit 1
    ;;
  esac
done

#apt install -y sysstat wrk2
if [ "$(basename "$PWD")" != "stress-testing" ]; then
  cd ./ci/stress-testing || {
    echo "Failed to change directory to ./ci/stress-testing"
    exit 1
  }
fi
yq -i '.server.listen.disable = false' dashboard_conf/conf.yaml
echo '[]' >"$filepath"
docker build -t hkccr.ccs.tencentyun.com/api7-dev/api7-ee-3-gateway:dev ../..
chmod +x ./run.sh
./run.sh start_cp
if [ ! -f dev-license ]; then
  # Check if the TOKEN variable is set
  if [ -z "$DEV_LICENSE" ]; then
    echo "Error: DEV_LICENSE environment variable is not set."
    exit 1
  fi

  # Create the dev-license file and write the TOKEN value into it
  echo "$DEV_LICENSE" >dev-license
  echo "dev-license file created from env variable."
fi
LICENSE=$(cat dev-license | sed ':a;N;$!ba;s/\n/\\n/g')
curl http://localhost:7080/api/license -X PUT -d "{\"data\":\"$LICENSE\"}" -u admin:admin -H "Content-Type: application/json"

#Invite a new user for test
user=$(curl http://localhost:7080/api/invites -X POST -d '{"password":"testing","username":"testing"}' -u admin:admin -H "Content-Type: application/json")
echo "user created: $user"
id=$(echo $user | jq .value.id | tr -d '"')
echo "generated user id is: $id"
curl "http://localhost:7080/api/users/$id/assigned_roles" -X PUT -d '{"roles":["super_admin_id"]}' -u admin:admin -H "Content-Type: application/json"
#generate token
value=$(curl http://localhost:7080/api/tokens -X POST -d '{"expires_at":0,"name":"test1"}' -u testing:testing -H "Content-Type: application/json")
echo "token response $value"
TOKEN=$(echo $value | jq .value.token | tr -d '"')

# Add support for -h flag
while getopts ":h" opt; do
  case ${opt} in
  h)
    echo "Usage: $0 -t <testID> -f <filepath>"
    echo "Use $0 list to see available tests"
    exit 0
    ;;
  \?)
    echo "Invalid option: $OPTARG" 1>&2
    exit 1
    ;;
  esac
done


if [[ "$testname" == "all" ]]; then
  # Source all test files in numerical order
  # Collect and sort test files using version sort
  test_files=()
  while IFS= read -r -d $'\0' file; do
    test_files+=("$file")
  done < <(printf '%s\0' ./tests/test*.sh | sort -Vz)

  # Source each sorted test file
  for test_file in "${test_files[@]}"; do
    source "$test_file"
  done
else
  # Try to source the specific test file
  test_file="./tests/$testname.sh"

  if [[ -f "$test_file" ]]; then
    source "$test_file"
  else
    echo "Test file '$test_file' not found"
    exit 1
  fi
fi
#----------------------------Complete cleanup----------------------------------#
./run.sh stop_cp
kill -9 $(lsof -i :7737 -t)
# rm before_cpu_mem.txt after_cpu_mem.txt wrk.txt before_cpu_mem_1.txt after_cpu_mem_1.txt during_cpu_mem.txt
cat "$filepath"

