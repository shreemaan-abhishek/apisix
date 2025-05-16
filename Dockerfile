# --- Form apisix-docker ---
# --- refer: https://github.com/apache/apisix-docker/blob/master/debian/Dockerfile
FROM debian:bullseye-slim AS runtime-builder

ARG RUNTIME_VERSION=1.2.1

RUN apt update && apt install -y wget gnupg ca-certificates
RUN set -ex; \
    arch=$(dpkg --print-architecture); \
    wget -O - https://openresty.org/package/pubkey.gpg | apt-key add -; \
    case "${arch}" in \
      amd64) \
        echo "deb https://openresty.org/package/debian bullseye openresty" | tee /etc/apt/sources.list.d/openresty.list \
        ;; \
      arm64) \
        echo "deb https://openresty.org/package/arm64/debian bullseye openresty" | tee /etc/apt/sources.list.d/openresty.list \
        ;; \
    esac; \
    set -ex; \
    arch=$(dpkg --print-architecture); \
    wget https://github.com/api7/apisix-build-tools/releases/download/api7ee-runtime/${RUNTIME_VERSION}/api7ee-runtime_${RUNTIME_VERSION}-0.debianbullseye-slim_${arch}.deb; \
    dpkg -i ./api7ee-runtime_${RUNTIME_VERSION}-0.debianbullseye-slim_${arch}.deb
RUN rm /usr/local/openresty/bin/etcdctl && rm -rf /usr/local/openresty/openssl3/share

FROM debian:bullseye-slim AS apisix-builder

ARG APISIX_VERSION=3.2.2

RUN apt update && apt-get -y install --no-install-recommends wget ca-certificates gnupg

RUN set -ex; \
    arch=$(dpkg --print-architecture); \
    codename=`grep -Po 'VERSION="[0-9]+ \(\K[^)]+' /etc/os-release`; \
    wget -O - https://openresty.org/package/pubkey.gpg | apt-key add -; \
    case "${arch}" in \
      amd64) \
        echo "deb https://openresty.org/package/debian $codename openresty" | tee /etc/apt/sources.list.d/openresty.list \
        && wget -O - https://repos.apiseven.com/pubkey.gpg | apt-key add - \
        && echo "deb https://repos.apiseven.com/packages/debian $codename main" | tee /etc/apt/sources.list.d/apisix.list \
        ;; \
      arm64) \
        echo "deb https://openresty.org/package/arm64/debian $codename openresty" | tee /etc/apt/sources.list.d/openresty.list \
        && wget -O - https://repos.apiseven.com/pubkey.gpg | apt-key add - \
        && echo "deb https://repos.apiseven.com/packages/arm64/debian $codename main" | tee /etc/apt/sources.list.d/apisix.list \
        ;; \
    esac; \
    apt update \
    && apt install -y apisix=${APISIX_VERSION}-0 \
    && apt-get purge -y --auto-remove \
    && apisix version \
    && rm -rf /usr/local/apisix/apisix/inspect \
    && rm -rf /usr/local/apisix/deps \
    && rm -f /usr/local/apisix/apisix/plugins/inspect.lua \
    && rm -f /etc/apt/sources.list.d/openresty.list /etc/apt/sources.list.d/apisix.list

FROM debian:bullseye-slim
COPY --from=runtime-builder /usr/local/openresty /usr/local/openresty
COPY --from=apisix-builder /usr/local/apisix /usr/local/apisix
COPY --from=apisix-builder /usr/bin/apisix /usr/bin/apisix

ENV PATH=$PATH:/usr/local/openresty/luajit/bin:/usr/local/openresty/nginx/sbin:/usr/local/openresty/bin

WORKDIR /usr/local/apisix

RUN apt update \
    && apt install libpcre3 debianutils -y \
    # forward request and error logs to docker log collector
    && ln -sf /dev/stdout /usr/local/apisix/logs/access.log \
    && ln -sf /dev/stderr /usr/local/apisix/logs/error.log

EXPOSE 9080 9443

COPY ./docker-entrypoint.sh /docker-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh"]

CMD ["docker-start"]

STOPSIGNAL SIGQUIT

# --- apisix-docker end ---
COPY ./lua-resty-openapi-validate /usr/local/apisix/lua-resty-openapi-validate
COPY ./lua-resty-aws-s3 /usr/local/apisix/lua-resty-aws-s3

COPY --chown=apisix:apisix ./apisix /usr/local/apisix/apisix
COPY --chown=apisix:apisix ./agent /usr/local/apisix/agent
COPY --chown=apisix:apisix ./conf/apisix.yaml /usr/local/apisix/conf/apisix.yaml
COPY --chown=apisix:apisix ./dp_conf.json /usr/local/apisix/dp_conf.json
COPY --chown=apisix:apisix ./conf/config.yaml /usr/local/apisix/conf/config.yaml
COPY --chown=apisix:apisix ./conf/config-default.yaml /usr/local/apisix/conf/config-default.yaml
COPY --chown=apisix:apisix ./ci/utils/api7-ljbc.sh /usr/local/apisix/api7-ljbc.sh
COPY --chown=apisix:apisix ./ci/utils/install-lua-resty-openapi-validate.sh /usr/local/apisix/ci/utils/install-lua-resty-openapi-validate.sh
COPY --chown=apisix:apisix ./ci/utils/install-lua-resty-aws-s3.sh /usr/local/apisix/ci/utils/install-lua-resty-aws-s3.sh
COPY --chown=apisix:apisix ./ci/utils/linux-install-luarocks.sh /usr/local/apisix/linux-install-luarocks.sh
COPY --chown=apisix:apisix ./Makefile /usr/local/apisix/Makefile
COPY --chown=apisix:apisix ./api7-master-0.rockspec /usr/local/apisix/api7-master-0.rockspec

USER root

RUN bash /usr/local/apisix/api7-ljbc.sh && rm /usr/local/apisix/api7-ljbc.sh

WORKDIR /usr/local/apisix

# build deps
RUN apt update \
    && apt-get -y install --no-install-recommends ca-certificates sudo gcc unzip make git wget zlib1g-dev libxml2-dev libxslt-dev libyaml-dev \
    && wget -O go.tar.gz https://go.dev/dl/go1.22.6.linux-$(dpkg --print-architecture).tar.gz && tar -C /usr/local -xzf go.tar.gz && rm -f go.tar.gz \
    && bash /usr/local/apisix/linux-install-luarocks.sh && rm /usr/local/apisix/linux-install-luarocks.sh \
    && export PATH=$PATH:/usr/local/go/bin CGO_ENABLED=1 \
    && luarocks config variables.OPENSSL_DIR /usr/local/openresty/openssl3 \
    && luarocks config variables.PCRE_DIR /usr/local/openresty/pcre \
    && ENV_OPENSSL_PREFIX=/usr/local/openresty/openssl3 make deps \
    && go clean -cache -modcache && rm -rf /usr/local/go \
    && SUDO_FORCE_REMOVE=yes apt-get -y purge --auto-remove --allow-remove-essential luarocks sudo gcc unzip make git wget golang-go \
    && groupadd --system --gid 636 apisix \
    && useradd --system --gid apisix --no-create-home --shell /usr/sbin/nologin --uid 636 apisix \
    && chown -R apisix:apisix /usr/local/apisix

USER apisix
