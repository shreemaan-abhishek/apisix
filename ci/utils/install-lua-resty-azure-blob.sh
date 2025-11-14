#!/usr/bin/env bash
set -exuo pipefail
PARENT_DIR=""
# Check if the first positional parameter is unbound
if [ -n "${1-}" ]; then
    PARENT_DIR=$1
fi
LIB_NAME=lua-resty-azure-blob
cd $LIB_NAME

# install lua-lib to directories under the lua_package_path and lua_package_cpath
sudo "PATH=$PATH" make INST_LUADIR="../$PARENT_DIR/deps/share/lua/5.1/" OUTPUT_NAME="../../$PARENT_DIR/deps/lib/lua/5.1/azblob.so" install
