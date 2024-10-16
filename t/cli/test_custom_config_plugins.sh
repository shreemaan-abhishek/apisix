#!/usr/bin/env bash

. ./t/cli/common.sh

echo '
plugins:
  - example-plugin
stream_plugins:
  - limit-conn
' > conf/config.yaml

make init

out=$(make run || true)

if ! echo "$out" | grep "WARNING: the plugins in config.yaml is no longer supported and will be ignored."; then
    echo "failed: pattern should match a line in error.log"
    exit 1
fi
if ! echo "$out" | grep "WARNING: the stream_plugins in config.yaml is no longer supported and will be ignored."; then
    echo "failed: pattern should match a line in error.log"
    exit 1
fi

make stop

echo "passed: test config plugins/stream_plugins in custom configuration"
