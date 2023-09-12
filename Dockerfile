FROM apache/apisix:3.2.1-debian

USER root

COPY ./api7-soap-proxy/soap_proxy.py /usr/local/api7-soap-proxy/soap_proxy.py
COPY ./api7-soap-proxy/requirements.txt /usr/local/api7-soap-proxy/requirements.txt
COPY ./api7-soap-proxy/logging.conf /usr/local/api7-soap-proxy/logging.conf
COPY ./docker-entrypoint.sh /docker-entrypoint.sh

COPY --chown=apisix:apisix ./apisix /usr/local/apisix/apisix

COPY --chown=apisix:apisix ./conf/config.yaml /usr/local/apisix/conf/config.yaml
COPY --chown=apisix:apisix ./conf/config-default.yaml /usr/local/apisix/conf/config-default.yaml

COPY --chown=apisix:apisix ./ci/utils/api7-ljbc.sh /usr/local/apisix/api7-ljbc.sh

WORKDIR /usr/local/api7-soap-proxy

RUN apt update && apt install -y python3 python3-pip && python3 -m pip install -r requirements.txt

RUN python3 -m compileall soap_proxy.py && mv __pycache__/soap_proxy.cpython-*.pyc soap_proxy.pyc && rm soap_proxy.py

WORKDIR /usr/local/apisix

RUN bash /usr/local/apisix/api7-ljbc.sh && rm /usr/local/apisix/api7-ljbc.sh
