#!/usr/bin/env python3

from flask import Flask, request
import cachetools
import json
import logging
import threading
import traceback
import zeep
import jsonpickle

app = Flask(__name__)

clients_lock = threading.Lock()
clients = cachetools.TTLCache(maxsize=64, ttl=60)


def to_json(obj):
    return json.dumps(
        obj, default=lambda o: hasattr(o, "__values__") and o.__values__ or o.__dict__
    )


@app.post("/<operation>")
@app.post("/<svc>/<operation>")
@app.post("/<svc>/<filename>/<operation>")
def soap_post(operation, svc=None, filename=None):
    try:
        wsdl_url = request.headers.get("X-WSDL-URL")
        if wsdl_url is None or not wsdl_url:
            return {"error": "Missing header: X-WSDL-URL"}, 400
        logger.info(f"user request {wsdl_url=} {operation=}")

        with clients_lock:
            try:
                cli = clients[wsdl_url]
            except KeyError:
                cli = None

        if not cli:
            cli = zeep.Client(wsdl_url)
            with clients_lock:
                clients[wsdl_url] = cli

        try:
            status = 200
            data = request.get_json(force=True)
            logger.info(f"req: {data}")
            body = cli.service[operation](**data)
        except zeep.exceptions.Fault as fault:
            status = 502
            body = fault
        logger.info(f"resp: {jsonpickle.encode(body)}")
        return to_json(body), status, {"content-type": "application/json"}
    except Exception as exc:
        tb = traceback.format_exc()
        logging.error(tb)
        return jsonpickle.encode(exc), 500, {"content-type": "application/json"}


if __name__ == "__main__":
    logging.basicConfig(
        format="%(asctime)s,%(msecs)d %(name)s %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
        level=logging.DEBUG,
    )
    logger = logging.getLogger(__name__)
    app.run(host="0.0.0.0", port=5000, debug=True)
else:
    gunicorn_logger = logging.getLogger("gunicorn.error")
    root_logger = logging.getLogger()
    root_logger.handlers = gunicorn_logger.handlers
    root_logger.setLevel(gunicorn_logger.level)
    logger = app.logger
