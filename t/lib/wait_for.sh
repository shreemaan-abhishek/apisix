#!/usr/bin/env bash

url=$1
timeout=$2
i=1
while ! curl -s "${url}" >/dev/null; do
  if [[ "$i" -gt "${timeout}" ]]; then
    echo "timeout occurred after waiting $timeout seconds"
    exit 1
  fi
  sleep 1
  echo "waited for ${url} $i seconds.."
  ((i++));
done
