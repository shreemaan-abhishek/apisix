# this Dockerfile is part of gateway's Dockerfile in project root,
# we need to start a standalone soap-proxy server for CI
FROM ubuntu:24.04

COPY ./api7-soap-proxy/soap_proxy.py /usr/local/api7-soap-proxy/soap_proxy.py
COPY ./api7-soap-proxy/requirements.txt /usr/local/api7-soap-proxy/requirements.txt
COPY ./api7-soap-proxy/logging.conf /usr/local/api7-soap-proxy/logging.conf

RUN groupadd --system --gid 636 apisix \
    && useradd --system --gid apisix --no-create-home --shell /usr/sbin/nologin --uid 636 apisix

WORKDIR /usr/local/api7-soap-proxy

RUN apt update && apt-get install -y --no-install-recommends python3 python3-pip gunicorn3 \
    && pip3 install -r requirements.txt --break-system-packages && pip3 cache purge \
    && python3 -m compileall soap_proxy.py \
    && mv __pycache__/soap_proxy.cpython-*.pyc soap_proxy.pyc && rm soap_proxy.py \
    && touch /var/log/api7_soap_proxy.access.log /var/log/api7_soap_proxy.error.log \
    && chown -R apisix:apisix /usr/local/api7-soap-proxy \
    && chown -R apisix:apisix /var/log/api7_soap_proxy.*

CMD ["gunicorn3", "--log-config", "logging.conf", "--bind", "0.0.0.0:5000", "--chdir", "/usr/local/api7-soap-proxy/", "soap_proxy:app"]

USER apisix
