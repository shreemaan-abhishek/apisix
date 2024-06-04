# --- Build etcdctl ---
# we can delete this part after etcd release a new version with go1.20+
FROM golang:1.21.5 AS builder

WORKDIR /go

RUN git clone -b release-3.5 https://github.com/etcd-io/etcd.git && cd etcd && make


# --- Form apisix-docker ---
# --- refer: https://github.com/apache/apisix-docker/blob/master/debian/Dockerfile
FROM debian:bullseye-slim

ARG APISIX_VERSION=3.2.2

RUN set -ex; \
    arch=$(dpkg --print-architecture); \
    apt update; \
    apt-get -y install --no-install-recommends wget gnupg cpanminus ca-certificates unzip make git zlib1g-dev gcc libxml2-dev libxslt-dev;\
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
    && rm -f /etc/apt/sources.list.d/openresty.list /etc/apt/sources.list.d/apisix.list \
    && rm /usr/local/openresty/bin/etcdctl \
    && openresty -V \
    && apisix version

WORKDIR /usr/local/apisix

ENV PATH=$PATH:/usr/local/openresty/luajit/bin:/usr/local/openresty/nginx/sbin:/usr/local/openresty/bin

# forward request and error logs to docker log collector
RUN ln -sf /dev/stdout /usr/local/apisix/logs/access.log \
    && ln -sf /dev/stderr /usr/local/apisix/logs/error.log

EXPOSE 9080 9443

COPY ./docker-entrypoint.sh /docker-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh"]

CMD ["docker-start"]

STOPSIGNAL SIGQUIT

# --- apisix-docker end ---

COPY ./api7-soap-proxy/soap_proxy.py /usr/local/api7-soap-proxy/soap_proxy.py
COPY ./api7-soap-proxy/requirements.txt /usr/local/api7-soap-proxy/requirements.txt
COPY ./api7-soap-proxy/logging.conf /usr/local/api7-soap-proxy/logging.conf
COPY ./lua-resty-openapi-validate /usr/local/apisix/lua-resty-openapi-validate
COPY ./lua-resty-aws-s3 /usr/local/apisix/lua-resty-aws-s3

COPY --chown=apisix:apisix ./apisix /usr/local/apisix/apisix
COPY --chown=apisix:apisix ./agent /usr/local/apisix/agent
COPY --chown=apisix:apisix ./conf/config.yaml /usr/local/apisix/conf/config.yaml
COPY --chown=apisix:apisix ./conf/config-default.yaml /usr/local/apisix/conf/config-default.yaml
COPY --chown=apisix:apisix ./ci/utils/api7-ljbc.sh /usr/local/apisix/api7-ljbc.sh
COPY --chown=apisix:apisix ./ci/utils/install-lua-resty-openapi-validate.sh /usr/local/apisix/ci/utils/install-lua-resty-openapi-validate.sh
COPY --chown=apisix:apisix ./ci/utils/install-lua-resty-aws-s3.sh /usr/local/apisix/ci/utils/install-lua-resty-aws-s3.sh
COPY --chown=apisix:apisix ./ci/utils/linux-install-luarocks.sh /usr/local/apisix/linux-install-luarocks.sh
COPY --chown=apisix:apisix ./ci/utils/linux-install-openssl3.sh /usr/local/apisix/linux-install-openssl3.sh
COPY --chown=apisix:apisix ./Makefile /usr/local/apisix/Makefile
COPY --chown=apisix:apisix ./api7-master-0.rockspec /usr/local/apisix/api7-master-0.rockspec

USER root

WORKDIR /usr/local/api7-soap-proxy

RUN apt install -y python3 python3-pip && python3 -m pip install -r requirements.txt && apt -y purge --auto-remove python3-pip python3-wheel python3-setuptools --allow-remove-essential

RUN python3 -m compileall soap_proxy.py && mv __pycache__/soap_proxy.cpython-*.pyc soap_proxy.pyc && rm soap_proxy.py

RUN touch /var/log/api7_soap_proxy.access.log /var/log/api7_soap_proxy.error.log

WORKDIR /usr/local/apisix

RUN bash /usr/local/apisix/api7-ljbc.sh && rm /usr/local/apisix/api7-ljbc.sh

RUN bash /usr/local/apisix/linux-install-luarocks.sh && rm /usr/local/apisix/linux-install-luarocks.sh

# install go
RUN case $(dpkg --print-architecture) in \
    amd64) export GO_ARCH='amd64' ;; \
    armhf) export GO_ARCH='armv6l' ;; \
    arm64) export GO_ARCH='arm64' ;; \
    *) export GO_ARCH='amd64' ;; \
    esac && \
    export GOLANG_DOWNLOAD_URL=https://golang.org/dl/go1.21.3.linux-$GO_ARCH.tar.gz; \
    wget -q "$GOLANG_DOWNLOAD_URL" -O go.tar.gz && \
    tar -C /usr/local -xzf go.tar.gz && \
    rm go.tar.gz && export PATH=$PATH:/usr/local/go/bin && export CGO_ENABLED=1 && apt-get install -y gcc sudo && \
    bash /usr/local/apisix/linux-install-openssl3.sh && rm /usr/local/apisix/linux-install-openssl3.sh && luarocks config variables.OPENSSL_DIR /usr/local/openresty/openssl3 && \
    ENV_OPENSSL_PREFIX=/usr/local/openresty/openssl3 make deps && go clean -cache &&  \
    rm -rf /usr/local/go && apt-get -y purge --auto-remove gcc --allow-remove-essential

COPY --from=builder /go/etcd/bin/etcdctl /usr/local/openresty/bin/etcdctl

RUN SUDO_FORCE_REMOVE=yes apt-get -y purge --auto-remove wget gnupg unzip make luarocks ca-certificates git sudo --allow-remove-essential

RUN groupadd --system --gid 636 apisix \
    && useradd --system --gid apisix --no-create-home --shell /usr/sbin/nologin --uid 636 apisix \
    && chown -R apisix:apisix /usr/local/apisix \
    && chown -R apisix:apisix /usr/local/api7-soap-proxy \
    && chown -R apisix:apisix /var/log/api7_soap_proxy.*

USER apisix
