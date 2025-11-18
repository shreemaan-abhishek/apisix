. ./t/cli/common.sh

echo '
apisix:
  node_listen:
    - 9080
    - port: 9082
      backlog: 4096
' > conf/config.yaml

make init

if ! grep "9080 default_server reuseport;" conf/nginx.conf > /dev/null; then
    echo "failed: undefined backlog"
    exit 1
fi

if ! grep "9082 default_server reuseport backlog=4096;" conf/nginx.conf > /dev/null; then
    echo "failed: define backlog"
    exit 1
fi

echo "passed: node listen backlog config"

echo '
apisix:
  ssl:
    listen:
      - port: 9443
      - port: 9445
        backlog: 1024
' > conf/config.yaml

make init

if ! grep "9443 ssl default_server reuseport;" conf/nginx.conf > /dev/null; then
    echo "failed: undefined backlog"
    exit 1
fi

if ! grep "9445 ssl default_server reuseport backlog=1024;" conf/nginx.conf > /dev/null; then
    echo "failed: define backlog"
    exit 1
fi

echo "passed: ssl listen backlog config"
