FROM debian:bullseye-slim

RUN apt update && apt install -y python3 python3-pip && pip3 install flask zeep jsonpickle cachetools

ADD ./soap-proxy.py /

CMD [ "python3", "-m", "flask", "--app", "/soap-proxy.py", "run", "-h", "0.0.0.0", "-p", "5001"]
