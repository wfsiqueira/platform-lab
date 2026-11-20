"""API de pedidos: aceita o pedido e o coloca na fila (Redis). Falha em ~2% e fica lenta em ~3%."""
import json
import os
import random
import time
import uuid

import redis
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from opentelemetry.propagate import inject

from common import jlog

FAIL_RATE = float(os.getenv("FAIL_RATE", "0.02"))
SLOW_RATE = float(os.getenv("SLOW_RATE", "0.03"))
r = redis.Redis(host=os.getenv("REDIS_HOST", "redis"), port=6379)
app = FastAPI()


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.post("/order")
def order():
    if random.random() < SLOW_RATE:
        time.sleep(0.7)
    if random.random() < FAIL_RATE:
        jlog("ERROR", "falha ao aceitar o pedido", reason="erro injetado")
        raise HTTPException(status_code=500, detail="erro injetado")
    oid = uuid.uuid4().hex[:12]
    carrier = {}
    inject(carrier)  # propaga o contexto do trace pela fila (W3C traceparent)
    r.lpush("orders", json.dumps({"id": oid, "carrier": carrier, "ts": time.time()}))
    jlog("INFO", "pedido aceito", order_id=oid)
    return JSONResponse({"id": oid}, status_code=202)
