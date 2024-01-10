#!/usr/bin/env bash

set -exuo pipefail

VAR_CUR_PATH="$(cd $(dirname ${0}); pwd)"
VAR_CUR_HOME="$(cd $(dirname ${0})/../..; pwd)"

source "${VAR_CUR_PATH}/linux-common.sh"

# =======================================
# Linux common config
# =======================================
export_or_prefix() {
    export OPENRESTY_PREFIX="/usr/local/openresty-debug"
    export PATH=$OPENRESTY_PREFIX/nginx/sbin:$OPENRESTY_PREFIX/luajit/bin:$OPENRESTY_PREFIX/bin:$PATH
}


get_apisix_code() {
    # ${1} branch name
    # ${2} checkout path
    git_branch=${1:-release/3.2}
    git_checkout_path=${2:-workbench}
    git clone --depth 1 --recursive https://github.com/apache/apisix.git \
        -b "${git_branch}" "${git_checkout_path}" && cd "${git_checkout_path}" || exit 1
}


patch_apisix_code(){
    # ${1} apisix home dir
    VAR_APISIX_HOME="${VAR_CUR_HOME}/${1:-workbench}"

    sed -ri -e "/make\s+ci-env-up/d" \
      -e "/linux-ci-init-service.sh/d" \
      "${VAR_APISIX_HOME}/ci/linux_openresty_common_runner.sh"
}


install_module() {
    # ${1} apisix home dir
    VAR_APISIX_HOME="${VAR_CUR_HOME}/${1:-workbench}"

    # copy ci utils script
    cp -av "${VAR_CUR_HOME}/ci" "${VAR_APISIX_HOME}"

    # copy custom apisix folder to origin apisix
    cp -av "${VAR_CUR_HOME}/apisix" "${VAR_APISIX_HOME}"

    # copy test case to origin apisix
    cp -av "${VAR_CUR_HOME}/t" "${VAR_APISIX_HOME}"

    cp -av "${VAR_CUR_HOME}/conf" "${VAR_APISIX_HOME}"

    cp -av "${VAR_CUR_HOME}/agent" "${VAR_APISIX_HOME}"

    # use ee's rockspec
    cp -av "${VAR_CUR_HOME}/api7-master-0.rockspec" "${VAR_APISIX_HOME}/rockspec/"
    sed -i 's/apisix-master-0.rockspec/api7-master-0.rockspec/g' "${VAR_APISIX_HOME}/Makefile"
    sed -i 's/API7/APISIX/g' "${VAR_APISIX_HOME}/apisix/init.lua"
}

test_env() {
    export_or_prefix

    ./bin/apisix init

    failed_msg="failed: failed to configure etcd host with reserved environment variable"

    # should failed
    out=$(API7_CONTROL_PLANE_ENDPOINTS='["http://127.0.0.1:2333"]' ./bin/apisix init_etcd 2>&1 || true)
    if ! echo "$out" | grep "connection refused"; then
        echo $failed_msg
        exit 1
    fi

    # should success
    out=$(API7_CONTROL_PLANE_ENDPOINTS='["http://127.0.0.1:2379"]' ./bin/apisix init_etcd 2>&1 || true)
    if echo "$out" | grep "connection refused" > /dev/null; then
        echo $failed_msg
        exit 1
    fi

}


run_case() {
    export_or_prefix

    ./bin/apisix init
    ./bin/apisix init_etcd

    git submodule update --init --recursive

    # test proxy-buffering plugin
    apt -y install python3
    pip3 install sseclient-py aiohttp-sse
    ./bin/apisix start
    sleep 2
    t/plugin/test_proxy_buffering.sh
    ./bin/apisix stop

    FLUSH_ETCD=1 prove -I../test-nginx/lib -I./ -r -s t/admin/routes2.t t/node/service-path-prefix.t \
        t/api7-agent \
        t/plugin/graphql-proxy-cache \
        t/plugin/traffic-label.t t/plugin/traffic-label2.t \
        t/plugin/limit-count-redis-cluster3.t t/plugin/limit-count-redis4.t t/plugin/limit-count5.t \
        t/plugin/soap.t \
        t/plugin/graphql-limit-count \
        t/plugin/api7-traffic-split*
}

# =======================================
# Entry
# =======================================
case_opt=$1
shift

case ${case_opt} in
get_apisix_code)
    get_apisix_code "$@"
    ;;
patch_apisix_code)
    patch_apisix_code "$@"
    ;;
install_module)
    install_module "$@"
    ;;
run_case)
    run_case "$@"
    ;;
test_env)
    test_env "$@"
    ;;
*)
    func_echo_error_status "Unknown method: ${case_opt}"
    exit 1
    ;;
esac
