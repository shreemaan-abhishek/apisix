FROM debian:bullseye-slim

ADD ./soap-proxy.py /
ADD ./requirements.txt /

RUN apt update && apt install -y python3 python3-pip && pip3 install -r /requirements.txt

CMD [ "python3", "/soap-proxy.py" ]
