. ./ci/common.sh

install_dependencies() {
    export_or_prefix
    export OPENRESTY_PREFIX="/usr/local/openresty"
    export PATH=$OPENRESTY_PREFIX/nginx/sbin:$OPENRESTY_PREFIX/luajit/bin:$OPENRESTY_PREFIX/bin:$PATH

    # install build & runtime deps
    yum install -y wget tar gcc gcc-c++ automake autoconf libtool make unzip patch \
        git sudo openldap-devel which ca-certificates openresty-pcre-devel openresty-zlib-devel lua-devel epel-release cpanminus perl

    # curl with http2
    wget https://github.com/moparisthebest/static-curl/releases/download/v7.79.1/curl-amd64 -qO /usr/bin/curl
    # install openresty to make apisix's rpm test work
    export luajit_xcflags="-DLUAJIT_ASSERT -DLUAJIT_NUMMODE=2 -DLUAJIT_ENABLE_LUA52COMPAT -O0"
    export debug_args=--with-debug
    yum install -y yum-utils && yum-config-manager --add-repo https://openresty.org/package/centos/openresty.repo
    yum install -y openresty-openssl111 openresty-openssl111-devel openresty-openssl111-debug-devel pcre pcre-devel openresty-zlib-devel libxml2-devel libxslt-devel

    # install newer curl
    yum makecache
    yum install -y libnghttp2-devel
    yum -y install centos-release-scl
    yum -y install devtoolset-9 patch

    set +eu
    source scl_source enable devtoolset-9
    set -eu

    export APISIX_RUNTIME=1.2.7
    wget "https://raw.githubusercontent.com/api7/apisix-build-tools/api7ee-runtime/${APISIX_RUNTIME}/build-api7ee-runtime.sh"
    chmod +x build-apisix-runtime.sh
    ./build-apisix-runtime.sh latest
    curl -k -o /usr/local/openresty/openssl3/ssl/openssl.cnf \
        https://raw.githubusercontent.com/api7/apisix-build-tools/api7ee-runtime/${APISIX_RUNTIME}/conf/openssl3/openssl.cnf

    # install luarocks
    ./utils/linux-install-luarocks.sh

    # install etcdctl
    ./ci/linux-install-etcd-client.sh

    # install vault cli capabilities
    install_vault_cli

    # install test::nginx
    yum install -y cpanminus perl
    cpanm --notest Test::Nginx IPC::Run > build.log 2>&1 || (cat build.log && exit 1)

    # add go1.15 binary to the path
    mkdir build-cache
    # centos-7 ci runs on a docker container with the centos image on top of ubuntu host. Go is required inside the container.
    cd build-cache/ && wget -q https://golang.org/dl/go1.17.linux-amd64.tar.gz && tar -xf go1.17.linux-amd64.tar.gz
    export PATH=$PATH:$(pwd)/go/bin
    cd ..
    # install and start grpc_server_example
    cd t/grpc_server_example

    CGO_ENABLED=0 go build
    ./grpc_server_example \
        -grpc-address :50051 -grpcs-address :50052 -grpcs-mtls-address :50053 -grpc-http-address :50054 \
        -crt ../certs/apisix.crt -key ../certs/apisix.key -ca ../certs/mtls_ca.crt \
        > grpc_server_example.log 2>&1 || (cat grpc_server_example.log && exit 1)&

    cd ../../
    # wait for grpc_server_example to fully start
    sleep 3

    # installing grpcurl
    install_grpcurl

    # install nodejs
    install_nodejs

    # grpc-web server && client
    cd t/plugin/grpc-web
    ./setup.sh
    # back to home directory
    cd ../../../

    # install dependencies
    git clone https://github.com/openresty/test-nginx.git test-nginx
    create_lua_deps
}

run_case() {
    export_or_prefix
    export OPENRESTY_PREFIX="/usr/local/openresty"
    export PATH=$OPENRESTY_PREFIX/nginx/sbin:$OPENRESTY_PREFIX/luajit/bin:$OPENRESTY_PREFIX/bin:$PATH

    make init
    set_coredns
    # run test cases
    FLUSH_ETCD=1 prove --timer -Itest-nginx/lib -I./ -r ${TEST_FILE_SUB_DIR} | tee /tmp/test.result
    rerun_flaky_tests /tmp/test.result
}

case_opt=$1
case $case_opt in
    (install_dependencies)
        install_dependencies
        ;;
    (run_case)
        run_case
        ;;
esac
