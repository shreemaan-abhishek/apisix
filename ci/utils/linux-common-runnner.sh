#!/usr/bin/env bash

set -exuo pipefail

VAR_CUR_PATH="$(cd $(dirname ${0}); pwd)"
VAR_CUR_HOME="$(cd $(dirname ${0})/../..; pwd)"

source "${VAR_CUR_PATH}/linux-common.sh"

# =======================================
# Linux common config
# =======================================
export_or_prefix() {
    export OPENRESTY_PREFIX="/usr/local/openresty"
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

    sed -i "s/npm.taobao.org/npmmirror.com/" ${VAR_APISIX_HOME}/t/plugin/grpc-web/package-lock.json

    sed -i "s/openssl111/openssl3/g" ${VAR_APISIX_HOME}/utils/linux-install-luarocks.sh
    echo "luarocks config variables.OPENSSL_DIR \${OPENSSL_PREFIX}" >> ${VAR_APISIX_HOME}/utils/linux-install-luarocks.sh
}


install_deps() {
    # run keycloak for saml test
    docker run --rm --name keycloak -d -p 8087:8080 -e KEYCLOAK_ADMIN=admin -e KEYCLOAK_ADMIN_PASSWORD=admin quay.io/keycloak/keycloak:18.0.2 start-dev

    # wait for keycloak ready
    bash -c 'while true; do curl -s localhost:8087 &>/dev/null; ret=$?; [[ $ret -eq 0 ]] && break; sleep 3; done'

    # configure keycloak for test
    wget https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -O jq
    chmod +x jq
    docker cp jq keycloak:/usr/bin/
    docker cp ci/kcadm_configure_saml.sh keycloak:/tmp/
    docker exec keycloak bash /tmp/kcadm_configure_saml.sh
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
    # remove grpc related test cases and lua files
    rm -f "${VAR_APISIX_HOME}/t/core/etcd-grpc-auth.t"
    rm -f "${VAR_APISIX_HOME}/t/core/etcd-grpc-mtls.t"
    rm -f "${VAR_APISIX_HOME}/t/core/grpc.t"
    rm -f "${VAR_APISIX_HOME}/t/plugin/hmac-auth-custom.t"
    rm -f "${VAR_APISIX_HOME}/t/plugin/opentelemetry-bugfix-pb-state.t"
    eval rm -f "${VAR_APISIX_HOME}/t/cli/test_etcd_grpc*"
    rm -f "${VAR_APISIX_HOME}/apisix/core/grpc.lua"
    cp -av "${VAR_CUR_HOME}/conf" "${VAR_APISIX_HOME}"

    cp -av "${VAR_CUR_HOME}/agent" "${VAR_APISIX_HOME}"

    cat "${VAR_CUR_HOME}/.luacheckrc" >> "${VAR_APISIX_HOME}/.luacheckrc"

    # remove some Lua files and test cases
    # inspect.t causes flaky test failure, and nobody uses it in ee so remove it:
    rm -rf "${VAR_APISIX_HOME}/apisix/inspect/"
    rm -f "${VAR_APISIX_HOME}/t/lib/test_inspect.lua"
    rm -f "${VAR_APISIX_HOME}/apisix/plugins/inspect.lua" "${VAR_APISIX_HOME}/t/plugin/inspect.t"
    sed -i '/\$(ENV_INSTALL) -d \$(ENV_INST_LUADIR)\/apisix\/inspect/d' "${VAR_APISIX_HOME}/Makefile"
    sed -i '/\$(ENV_INSTALL) apisix\/inspect\/\*\.lua \$(ENV_INST_LUADIR)\/apisix\/inspect\//d' "${VAR_APISIX_HOME}/Makefile"

    # use ee's rockspec
    cp -av "${VAR_CUR_HOME}/api7-master-0.rockspec" "${VAR_APISIX_HOME}/rockspec/"
    sed -i 's/apisix-master-0.rockspec/api7-master-0.rockspec/g' "${VAR_APISIX_HOME}/Makefile"
    sed -i 's/\$(addprefix \$(ENV_NGINX_PREFIX), openssl111)/\$(addprefix \$(ENV_NGINX_PREFIX), openssl3)/g' "${VAR_APISIX_HOME}/Makefile"
    sed -i 's/\$(ENV_HOMEBREW_PREFIX)\/opt\/openresty-openssl111/\$(ENV_HOMEBREW_PREFIX)\/opt\/openresty-openssl3/g' "${VAR_APISIX_HOME}/Makefile"

    sed -i 's/API7/APISIX/g' "${VAR_APISIX_HOME}/apisix/init.lua"
    sed -i '/npm config set registry/ i \    npm config set strict-ssl false\n' "${VAR_APISIX_HOME}/ci/common.sh"

    # ensure APISIX's `make install` test passes (make install is tested by diffing apisix dir with install dir using diff -rq)
    # https://github.com/apache/apisix/blob/77704832ec91117f5ca7171811ae5f0d3f1494fe/ci/linux_apisix_current_luarocks_runner.sh#L40-L41
    sed -i '298i __to_replace__	$(ENV_INSTALL) -d $(ENV_INST_LUADIR)/apisix/plugins/trace' "${VAR_APISIX_HOME}/Makefile"
    sed -i '299i __to_replace__	$(ENV_INSTALL) apisix/plugins/trace/*.lua $(ENV_INST_LUADIR)/apisix/plugins/trace/' "${VAR_APISIX_HOME}/Makefile"

    sed -i '300i __to_replace__	$(ENV_INSTALL) -d $(ENV_INST_LUADIR)/apisix/plugins/toolset' "${VAR_APISIX_HOME}/Makefile"
    sed -i '301i __to_replace__	$(ENV_INSTALL) apisix/plugins/toolset/*.lua $(ENV_INST_LUADIR)/apisix/plugins/toolset/' "${VAR_APISIX_HOME}/Makefile"

    sed -i '302i __to_replace__	$(ENV_INSTALL) -d $(ENV_INST_LUADIR)/apisix/plugins/toolset/src/table-count' "${VAR_APISIX_HOME}/Makefile"
    sed -i '303i __to_replace__	$(ENV_INSTALL) apisix/plugins/toolset/src/table-count/*.lua $(ENV_INST_LUADIR)/apisix/plugins/toolset/src/table-count/' "${VAR_APISIX_HOME}/Makefile"
    sed -i '303i __to_replace__	$(ENV_INSTALL) apisix/plugins/toolset/src/*.lua $(ENV_INST_LUADIR)/apisix/plugins/toolset/src/' "${VAR_APISIX_HOME}/Makefile"

    sed -i '304i __to_replace__	$(ENV_INSTALL) -d $(ENV_INST_LUADIR)/apisix/plugins/ai-proxy' "${VAR_APISIX_HOME}/Makefile"
    sed -i '305i __to_replace__	$(ENV_INSTALL) apisix/plugins/ai-proxy/*.lua $(ENV_INST_LUADIR)/apisix/plugins/ai-proxy' "${VAR_APISIX_HOME}/Makefile"

    sed -i '306i __to_replace__	$(ENV_INSTALL) -d $(ENV_INST_LUADIR)/apisix/plugins/ai-proxy/drivers' "${VAR_APISIX_HOME}/Makefile"
    sed -i '307i __to_replace__	$(ENV_INSTALL) apisix/plugins/ai-proxy/drivers/*.lua $(ENV_INST_LUADIR)/apisix/plugins/ai-proxy/drivers' "${VAR_APISIX_HOME}/Makefile"

    sed -i '308i __to_replace__	$(ENV_INSTALL) -d $(ENV_INST_LUADIR)/apisix/plugins/jwt-auth' "${VAR_APISIX_HOME}/Makefile"
    sed -i '309i __to_replace__	$(ENV_INSTALL) apisix/plugins/jwt-auth/*.lua $(ENV_INST_LUADIR)/apisix/plugins/jwt-auth' "${VAR_APISIX_HOME}/Makefile"

    sed -i '310i __to_replace__	$(ENV_INSTALL) -d $(ENV_INST_LUADIR)/apisix/plugins/limit-count-advanced' "${VAR_APISIX_HOME}/Makefile"
    sed -i '311i __to_replace__	$(ENV_INSTALL) apisix/plugins/limit-count-advanced/*.lua $(ENV_INST_LUADIR)/apisix/plugins/limit-count-advanced/' "${VAR_APISIX_HOME}/Makefile"

    sed -i '312i __to_replace__	$(ENV_INSTALL) -d $(ENV_INST_LUADIR)/apisix/plugins/limit-count-advanced/sliding-window/store' "${VAR_APISIX_HOME}/Makefile"
    sed -i '313i __to_replace__	$(ENV_INSTALL) apisix/plugins/limit-count-advanced/sliding-window/store/*.lua $(ENV_INST_LUADIR)/apisix/plugins/limit-count-advanced/sliding-window/store' "${VAR_APISIX_HOME}/Makefile"

    sed -i '314i __to_replace__	$(ENV_INSTALL) -d $(ENV_INST_LUADIR)/apisix/plugins/limit-count-advanced/sliding-window' "${VAR_APISIX_HOME}/Makefile"
    sed -i '315i __to_replace__	$(ENV_INSTALL) apisix/plugins/limit-count-advanced/sliding-window/*.lua $(ENV_INST_LUADIR)/apisix/plugins/limit-count-advanced/sliding-window' "${VAR_APISIX_HOME}/Makefile"

    sed -i '308i __to_replace__	$(ENV_INSTALL) -d $(ENV_INST_LUADIR)/apisix/core/sandbox' "${VAR_APISIX_HOME}/Makefile"
    sed -i '309i __to_replace__	$(ENV_INSTALL) apisix/core/sandbox/*.lua $(ENV_INST_LUADIR)/apisix/core/sandbox' "${VAR_APISIX_HOME}/Makefile"

    sed -i '310i __to_replace__	$(ENV_INSTALL) -d $(ENV_INST_LUADIR)/apisix/plugins/jwt-auth' "${VAR_APISIX_HOME}/Makefile"
    sed -i '311i __to_replace__	$(ENV_INSTALL) apisix/plugins/jwt-auth/*.lua $(ENV_INST_LUADIR)/apisix/plugins/jwt-auth' "${VAR_APISIX_HOME}/Makefile"
    echo '
### ci-env-stop : CI env temporary stop
.PHONY: ci-env-stop
ci-env-stop:
	@$(call func_echo_status, "$@ -> [ Start ]")
	$(ENV_DOCKER_COMPOSE) stop
	@$(call func_echo_success_status, "$@ -> [ Done ]")' >> ${VAR_APISIX_HOME}/Makefile
    sed -i 's/__to_replace__//g' "${VAR_APISIX_HOME}/Makefile"

    # openssl
    sed -i '24i __to_replace__    export OPENSSL111_BIN=$OPENRESTY_PREFIX/openssl111/bin/openssl' "${VAR_APISIX_HOME}/ci/common.sh"
    sed -i 's/__to_replace__//g' "${VAR_APISIX_HOME}/ci/common.sh"

    sed -i 's|"error"|"\\[error\\]"|' "${VAR_APISIX_HOME}/t/fuzzing/public.py"


sed -i '/\.PHONY: stop/,/@\$(call func_echo_success_status, "\$@ -> \[ Done \]")/c \
.PHONY: stop\nstop: runtime\n\t@$(call func_echo_status, "$@ -> [ Start ]")\n\t$(ENV_APISIX) stop\n\t@sleep 0.5\n\t@for i in {1..6}; do \\\n\t\tif [ -f logs/nginx.pid ]; then \\\n\t\t\techo "nginx.pid still exists, waiting for the server to stop..."; \\\n\t\t\tsleep 1; \\\n\t\telse \\\n\t\t\tbreak; \\\n\t\tfi; \\\n\tdone;\n\t@$(call func_echo_success_status, "$@ -> [ Done ]")' ${VAR_APISIX_HOME}/Makefile

    cat "${VAR_APISIX_HOME}/Makefile"
    printf "\n\n"
    cat "${VAR_APISIX_HOME}/.luacheckrc"

    # after this PR: https://github.com/api7/api7-ee-3-gateway/pull/426/files
    # stream_proxy.only should be specified explicitly
    sed -i '28i\        only: true' "${VAR_APISIX_HOME}/t/cli/test_stream_config.sh"
    sed -i '30i\        only: false' "${VAR_APISIX_HOME}/t/cli/test_prometheus_stream.sh"

    # remove conf_server based files:
    rm -f "${VAR_APISIX_HOME}/apisix/cli/snippet.lua"
    rm -f "${VAR_APISIX_HOME}/t/bin/gen_snippet.lua"
    rm -f "${VAR_APISIX_HOME}/t/cli/test_deployment_mtls.sh"
    rm -f "${VAR_APISIX_HOME}/t/deployment/conf_server.t"
    rm -f "${VAR_APISIX_HOME}/t/deployment/conf_server2.t"
    rm -f "${VAR_APISIX_HOME}/t/deployment/mtls.t"

    touch "${VAR_APISIX_HOME}/ci/pod/otelcol-contrib/data-otlp.json"
    chmod 777 "${VAR_APISIX_HOME}/ci/pod/otelcol-contrib/data-otlp.json"
}

start_sse_server_example() {
    # build sse_server_example
    pushd t/sse_server_example
    go build
    ./sse_server_example 7737 2>&1 &

    for (( i = 0; i <= 10; i++ )); do
        sleep 0.5
        SSE_PROC=`ps -ef | grep sse_server_example | grep -v grep || echo "none"`
        if [[ $SSE_PROC == "none" || "$i" -eq 10 ]]; then
            echo "failed to start sse_server_example"
            ss -antp | grep 7737 || echo "no proc listen port 7737"
            exit 1
        else
            break
        fi
    done
    popd
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
install_deps)
    install_deps "$@"
    ;;
start_sse_server_example)
    start_sse_server_example "$@"
    ;;
*)
    func_echo_error_status "Unknown method: ${case_opt}"
    exit 1
    ;;
esac
