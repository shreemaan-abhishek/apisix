#!/bin/bash

dirs=("./apisix" "./agent")

for dir in "${dirs[@]}"; do
    find "$dir" -type f -name '*.lua' | while read -r file
    do
        root=$(dirname "$file")
        if [[ ! "$root" =~ .*cli$ ]]; then
            /usr/local/openresty/luajit/bin/luajit -bg "$file" "$file" || exit 1
        fi
    done
done
