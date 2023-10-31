# --- Build etcdctl ---
# we can delete this part after etcd release a new version with go1.20+
FROM golang:1.21.2 AS builder

WORKDIR /go

RUN git clone -b release-3.5 https://github.com/etcd-io/etcd.git && cd etcd && make


# --- Form apisix-docker ---
# --- refer: https://github.com/apache/apisix-docker/blob/master/debian/Dockerfile
FROM debian:bullseye-slim

ARG APISIX_VERSION=3.2.1

RUN set -ex; \
    arch=$(dpkg --print-architecture); \
    apt update; \
    apt-get -y install --no-install-recommends wget gnupg ca-certificates curl unzip make;\
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

RUN groupadd --system --gid 636 apisix \
    && useradd --system --gid apisix --no-create-home --shell /usr/sbin/nologin --uid 636 apisix \
    && chown -R apisix:apisix /usr/local/apisix

USER apisix

# forward request and error logs to docker log collector
RUN ln -sf /dev/stdout /usr/local/apisix/logs/access.log \
    && ln -sf /dev/stderr /usr/local/apisix/logs/error.log

EXPOSE 9080 9443

COPY ./docker-entrypoint.sh /docker-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh"]

CMD ["docker-start"]

STOPSIGNAL SIGQUIT

# --- apisix-docker end ---

USER root

COPY ./api7-soap-proxy/soap_proxy.py /usr/local/api7-soap-proxy/soap_proxy.py
COPY ./api7-soap-proxy/requirements.txt /usr/local/api7-soap-proxy/requirements.txt
COPY ./api7-soap-proxy/logging.conf /usr/local/api7-soap-proxy/logging.conf

COPY --chown=apisix:apisix ./apisix /usr/local/apisix/apisix
COPY --chown=apisix:apisix ./conf/config.yaml /usr/local/apisix/conf/config.yaml
COPY --chown=apisix:apisix ./conf/config-default.yaml /usr/local/apisix/conf/config-default.yaml
COPY --chown=apisix:apisix ./ci/utils/api7-ljbc.sh /usr/local/apisix/api7-ljbc.sh
COPY --chown=apisix:apisix ./ci/utils/linux-install-luarocks.sh /usr/local/apisix/linux-install-luarocks.sh
COPY --chown=apisix:apisix ./Makefile /usr/local/apisix/Makefile
COPY --chown=apisix:apisix ./api7-master-0.rockspec /usr/local/apisix/api7-master-0.rockspec

WORKDIR /usr/local/api7-soap-proxy

RUN apt install -y python3 python3-pip && python3 -m pip install -r requirements.txt && apt -y purge --auto-remove python3-pip python3-wheel python3-setuptools --allow-remove-essential

RUN python3 -m compileall soap_proxy.py && mv __pycache__/soap_proxy.cpython-*.pyc soap_proxy.pyc && rm soap_proxy.py

WORKDIR /usr/local/apisix

RUN bash /usr/local/apisix/api7-ljbc.sh && rm /usr/local/apisix/api7-ljbc.sh

RUN bash /usr/local/apisix/linux-install-luarocks.sh && rm /usr/local/apisix/linux-install-luarocks.sh

RUN make deps && rm /usr/local/apisix/Makefile && rm /usr/local/apisix/api7-master-0.rockspec

COPY --from=builder /go/etcd/bin/etcdctl /usr/local/openresty/bin/etcdctl

RUN apt-get -y purge --auto-remove curl wget gnupg unzip make luarocks ca-certificates --allow-remove-essential
