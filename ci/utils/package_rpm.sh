#!/usr/bin/env bash

set -ex

# install openresty to encode lua code
apt-get -y install --no-install-recommends wget gnupg ca-certificates
wget -O - https://openresty.org/package/pubkey.gpg | apt-key add -
echo "deb http://openresty.org/package/ubuntu $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/openresty.list
apt-get update
apt-get -y install openresty

# encode lua source code to luajit bytecode
bash ./ci/utils/api7-ljbc.sh

# move codes under build tool
mkdir ./apisix-build-tools/apisix
for dir in $(ls | grep -v "^apisix-build-tools$" | grep -v "^t$" | grep -v "^Dockerfile.centos$");do
    mv "$dir" ./apisix-build-tools/apisix/
done

# use local codes to build rpm package
cd apisix-build-tools

# replace the script to install luarocks
sed -i 's@https://raw.githubusercontent.com/apache/apisix/master/utils/linux-install-luarocks.sh@https://raw.githubusercontent.com/apache/apisix/release/3.2/utils/linux-install-luarocks.sh@' ./utils/install-common.sh

ls -l ./apisix/apisix
ls -l ./apisix/apisix/plugins

# build apisix with apisix-base as the dependency
make package type=rpm app=apisix version="${VERSION}" checkout=feat/ht_msg_pub image_base=centos image_tag=7 local_code_path=./apisix openresty=apisix-base artifact=api7-gateway

cd ..
