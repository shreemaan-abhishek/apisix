FROM apache/apisix:3.2.1-debian

COPY --chown=apisix:apisix ./apisix /usr/local/apisix/apisix

COPY --chown=apisix:apisix ./conf/config-default.yaml /usr/local/apisix/conf/config-default.yaml

COPY --chown=apisix:apisix ./ci/utils/api7-ljbc.sh /usr/local/apisix/api7-ljbc.sh

RUN bash /usr/local/apisix/api7-ljbc.sh && rm /usr/local/apisix/api7-ljbc.sh
