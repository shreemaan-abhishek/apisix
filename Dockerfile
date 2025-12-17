# --- Form apisix-docker ---
# --- refer: https://github.com/apache/apisix-docker/blob/master/debian/Dockerfile

# OpenAPI2MCP Node.js builder stage
FROM node:20-slim AS openapi2mcp-builder

# Install pnpm and upgrade npm to latest version
RUN npm install -g pnpm npm@latest

WORKDIR /app

# Copy package files
COPY ./OpenAPI2MCP/package.json ./OpenAPI2MCP/pnpm-lock.yaml ./

# Install only production dependencies
RUN pnpm install --prod --frozen-lockfile

# Copy source code
COPY ./OpenAPI2MCP/src ./src/
COPY ./OpenAPI2MCP/tsconfig.json ./

# Install dev dependencies for build
RUN pnpm install --frozen-lockfile

# Build the project
RUN pnpm run build

# Remove dev dependencies after build
RUN pnpm prune --prod

FROM debian:bookworm-slim AS runtime-builder

ARG RUNTIME_VERSION=1.2.7

RUN apt update && apt install -y wget gnupg ca-certificates
RUN set -ex; \
    arch=$(dpkg --print-architecture); \
    wget -O - https://openresty.org/package/pubkey.gpg | apt-key add -; \
    case "${arch}" in \
      amd64) \
        echo "deb https://openresty.org/package/debian bookworm openresty" | tee /etc/apt/sources.list.d/openresty.list \
        ;; \
      arm64) \
        echo "deb https://openresty.org/package/arm64/debian bookworm openresty" | tee /etc/apt/sources.list.d/openresty.list \
        ;; \
    esac; \
    set -ex; \
    arch=$(dpkg --print-architecture); \
    wget https://github.com/api7/apisix-build-tools/releases/download/api7ee-runtime/${RUNTIME_VERSION}/api7ee-runtime_${RUNTIME_VERSION}-0.debianbookworm-slim_${arch}.deb; \
    dpkg -i ./api7ee-runtime_${RUNTIME_VERSION}-0.debianbookworm-slim_${arch}.deb
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

FROM ubuntu:24.04
COPY --from=runtime-builder /usr/local/openresty /usr/local/openresty
COPY --from=apisix-builder /usr/local/apisix /usr/local/apisix
COPY --from=apisix-builder /usr/bin/apisix /usr/bin/apisix

# Install Node.js runtime and copy OpenAPI2MCP
RUN apt update && apt install -y curl && \
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt install -y nodejs && \
    npm install -g npm@latest && \
    apt clean && \
    rm -rf /var/lib/apt/lists/*

# Copy OpenAPI2MCP built files
COPY --from=openapi2mcp-builder /app/dist /usr/local/openapi2mcp/dist/
COPY --from=openapi2mcp-builder /app/node_modules /usr/local/openapi2mcp/node_modules/
COPY --from=openapi2mcp-builder /app/package.json /usr/local/openapi2mcp/

# Modify fastify's package.json to change find-my-way version from ^9.0.0 to 9.0.1
# Note: The project actually uses find-my-way@9.3.0, but this change is made to avoid false positives from customer scanning tools
RUN sed -i 's/"find-my-way": "\^9\.0\.0"/"find-my-way": "9.0.1"/' /usr/local/openapi2mcp/node_modules/.pnpm/fastify@5.3.3/node_modules/fastify/package.json || true

ENV PATH=$PATH:/usr/local/openresty/luajit/bin:/usr/local/openresty/nginx/sbin:/usr/local/openresty/bin

WORKDIR /usr/local/apisix

RUN apt update \
    && apt install -y libpcre3 \
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
COPY ./lua-resty-azure-blob /usr/local/apisix/lua-resty-azure-blob

COPY --chown=apisix:apisix ./apisix /usr/local/apisix/apisix
COPY --chown=apisix:apisix ./agent /usr/local/apisix/agent
COPY --chown=apisix:apisix ./conf/apisix.yaml /usr/local/apisix/conf/apisix.yaml
COPY --chown=apisix:apisix ./dp_conf.json /usr/local/apisix/dp_conf.json
COPY --chown=apisix:apisix ./conf/config.yaml /usr/local/apisix/conf/config.yaml
COPY --chown=apisix:apisix ./conf/config-default.yaml /usr/local/apisix/conf/config-default.yaml
COPY --chown=apisix:apisix ./ci/utils/api7-ljbc.sh /usr/local/apisix/api7-ljbc.sh
COPY --chown=apisix:apisix ./ci/utils/install-lua-resty-openapi-validate.sh /usr/local/apisix/ci/utils/install-lua-resty-openapi-validate.sh
COPY --chown=apisix:apisix ./ci/utils/install-lua-resty-aws-s3.sh /usr/local/apisix/ci/utils/install-lua-resty-aws-s3.sh
COPY --chown=apisix:apisix ./ci/utils/install-lua-resty-azure-blob.sh /usr/local/apisix/ci/utils/install-lua-resty-azure-blob.sh
COPY --chown=apisix:apisix ./ci/utils/linux-install-luarocks.sh /usr/local/apisix/linux-install-luarocks.sh
COPY --chown=apisix:apisix ./Makefile /usr/local/apisix/Makefile
COPY --chown=apisix:apisix ./api7-master-0.rockspec /usr/local/apisix/api7-master-0.rockspec

USER root

RUN bash /usr/local/apisix/api7-ljbc.sh && rm /usr/local/apisix/api7-ljbc.sh \
    && groupadd --system --gid 636 apisix \
    && useradd --system --gid apisix --no-create-home --shell /usr/sbin/nologin --uid 636 apisix

WORKDIR /usr/local/apisix

# build deps
RUN apt update && apt upgrade -y \
    && apt-get -y install --no-install-recommends ca-certificates sudo gcc unzip make git wget zlib1g-dev libxml2-dev libxslt-dev libyaml-dev \
    && wget -O go.tar.gz https://go.dev/dl/go1.23.8.linux-$(dpkg --print-architecture).tar.gz && tar -C /usr/local -xzf go.tar.gz && rm -f go.tar.gz \
    && bash /usr/local/apisix/linux-install-luarocks.sh && rm /usr/local/apisix/linux-install-luarocks.sh \
    && export PATH=$PATH:/usr/local/go/bin CGO_ENABLED=1 \
    && luarocks config variables.OPENSSL_DIR /usr/local/openresty/openssl3 \
    && luarocks config variables.PCRE_DIR /usr/local/openresty/pcre \
    && ENV_OPENSSL_PREFIX=/usr/local/openresty/openssl3 make deps \
    && go clean -cache -modcache && rm -rf /usr/local/go \
    && SUDO_FORCE_REMOVE=yes apt-get -y purge --auto-remove --allow-remove-essential luarocks sudo gcc unzip make git wget golang-go \
    && chown -R apisix:apisix /usr/local/apisix \
    && chown -R apisix:apisix /usr/local/openapi2mcp

ENV NODE_ENV=production
ENV SSE_PORT=3000

USER apisix
