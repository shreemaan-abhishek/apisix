# Makefile basic env setting
.DEFAULT_GOAL := help
## add pipefail support for default shell
SHELL := /bin/bash -o pipefail

# Project basic setting
project_name      ?= apisix-plugin-template
project_version   ?= 0.0.1
project_ci_runner ?= $(CURDIR)/ci/utils/linux-common-runnner.sh
ENV_LUAROCKS           ?= luarocks

REGISTRY ?= hkccr.ccs.tencentyun.com
REGISTRY_NAMESPACE ?= api7-dev
IMAGE_TAG ?= dev

# Hyper-converged Infrastructure
ENV_OS_NAME          ?= $(shell uname -s | tr '[:upper:]' '[:lower:]')
ENV_HELP_PREFIX_SIZE ?= 15
ENV_HELP_AWK_RULE    ?= '{ if(match($$0, /^\s*\#{3}\s*([^:]+)\s*:\s*(.*)$$/, res)){ printf("    make %-$(ENV_HELP_PREFIX_SIZE)s : %-10s\n", res[1], res[2]) } }'
ENV_OPENSSL_PREFIX   ?= /usr/local/openresty/openssl

# ENV patch for darwin
ifeq ($(ENV_OS_NAME), darwin)
	ENV_HELP_AWK_RULE := '{ if(match($$0, /^\#{3}([^:]+):(.*)$$/)){ split($$0, res, ":"); gsub(/^\#{3}[ ]*/, "", res[1]); _desc=$$0; gsub(/^\#{3}([^:]+):[ \t]*/, "", _desc); printf("    make %-$(ENV_HELP_PREFIX_SIZE)s : %-10s\n", res[1], _desc) } }'
	ENV_LUAROCKS := $(ENV_LUAROCKS) --lua-dir=$(ENV_HOMEBREW_PREFIX)/opt/lua@5.1
endif

ifneq ($(shell whoami), root)
	ENV_LUAROCKS_FLAG_LOCAL := --local
endif

ifdef ENV_LUAROCKS_SERVER
	ENV_LUAROCKS_SERVER_OPT := --server $(ENV_LUAROCKS_SERVER)
endif


# Makefile basic extension function
_color_red    =\E[1;31m
_color_green  =\E[1;32m
_color_yellow =\E[1;33m
_color_blue   =\E[1;34m
_color_wipe   =\E[0m
_echo_format  ="[%b info %b] %s\n"


define func_echo_status
	printf $(_echo_format) "$(_color_blue)" "$(_color_wipe)" $(1)
endef


define func_echo_warn_status
	printf $(_echo_format) "$(_color_yellow)" "$(_color_wipe)" $(1)
endef


define func_echo_success_status
	printf $(_echo_format) "$(_color_green)" "$(_color_wipe)" $(1)
endef


define func_echo_error_status
	printf $(_echo_format) "$(_color_red)" "$(_color_wipe)" $(1)
endef


# Makefile target
### help : Show Makefile rules
.PHONY: help
help:
	@$(call func_echo_success_status, "Makefile rules:")
	@echo
	@awk $(ENV_HELP_AWK_RULE) Makefile
	@echo


### init_apisix : Fetch apisix code
.PHONY: init_apisix
init_apisix:
	@$(call func_echo_status, "$@ -> [ Start ]")
	$(project_ci_runner) get_apisix_code
	@$(call func_echo_success_status, "$@ -> [ Done ]")


### patch_apisix : Patch apisix code
.PHONY: patch_apisix
patch_apisix:
	@$(call func_echo_status, "$@ -> [ Start ]")
	$(project_ci_runner) patch_apisix_code
	@$(call func_echo_success_status, "$@ -> [ Done ]")


### install : Install custom plugin
.PHONY: install
install:
	@$(call func_echo_status, "$@ -> [ Start ]")
	$(project_ci_runner) install_module
	@$(call func_echo_success_status, "$@ -> [ Done ]")


### deps : Installing dependencies
.PHONY: deps
deps:
	$(eval ENV_LUAROCKS_VER := $(shell $(ENV_LUAROCKS) --version | grep -E -o "luarocks [0-9]+."))
	@if [ '$(ENV_LUAROCKS_VER)' = 'luarocks 3.' ]; then \
		mkdir -p ~/.luarocks; \
		$(ENV_LUAROCKS) config $(ENV_LUAROCKS_FLAG_LOCAL) variables.OPENSSL_LIBDIR $(addprefix $(ENV_OPENSSL_PREFIX), /lib); \
		$(ENV_LUAROCKS) config $(ENV_LUAROCKS_FLAG_LOCAL) variables.OPENSSL_INCDIR $(addprefix $(ENV_OPENSSL_PREFIX), /include); \
		[ '$(ENV_OS_NAME)' == 'darwin' ] && $(ENV_LUAROCKS) config $(ENV_LUAROCKS_FLAG_LOCAL) variables.PCRE_INCDIR $(addprefix $(ENV_PCRE_PREFIX), /include); \
		$(ENV_LUAROCKS) install api7-master-0.rockspec --tree deps --only-deps $(ENV_LUAROCKS_SERVER_OPT); \
	else \
		$(call func_echo_warn_status, "WARNING: You're not using LuaRocks 3.x; please remove the luarocks and reinstall it via https://raw.githubusercontent.com/apache/apisix/master/utils/linux-install-luarocks.sh"); \
		exit 1; \
	fi
	./ci/utils/install-lua-resty-openapi-validate.sh
	./ci/utils/install-lua-resty-aws-s3.sh

.PHONY: build-image-pre
build-image-pre:
	@sed -i '/- server-info/d' conf/config-default.yaml
	@sed -i 's/#- opentelemetry/- opentelemetry/' conf/config-default.yaml
	@sed -i 's/#- batch-request/- batch-request/' conf/config-default.yaml


### Build docker image
.PHONY: build-image
build-image: build-image-pre
	docker build -t ${REGISTRY}/${REGISTRY_NAMESPACE}/api7-ee-3-gateway:${IMAGE_TAG} .


### Push docker image
.PHONY: push-image
push-image: build-image-pre
	@docker buildx build --push -t ${REGISTRY}/${REGISTRY_NAMESPACE}/api7-ee-3-gateway:${IMAGE_TAG} --platform linux/amd64,linux/arm64 .
	@if docker run --entrypoint cat --rm -i ${REGISTRY}/${REGISTRY_NAMESPACE}/api7-ee-3-gateway:${IMAGE_TAG} /usr/local/apisix/apisix/core.lua | file - | grep -q 'ASCII text'; then echo "code obfuscation did not work"; exit 1; fi
