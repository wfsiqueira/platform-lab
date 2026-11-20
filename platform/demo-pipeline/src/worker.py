"""Worker: consome a fila e continua o trace da API. Falha em ~5% e demora 2s em ~5%."""
import json
import os
import random
import time

import redis
from opentelemetry import metrics, trace
from opentelemetry.propagate import extract

from common import jlog

r = redis.Redis(host=os.getenv("REDIS_HOST", "redis"), port=6379)
tracer = trace.get_tracer("worker")
meter = metrics.get_meter("worker")
processed = meter.create_counter("orders_processed", description="Pedidos processados")
duration = meter.create_histogram("order_processing_seconds", unit="s", description="Tempo por pedido")

FAIL_RATE = float(os.getenv("FAIL_RATE", "0.05"))
SLOW_RATE = float(os.getenv("SLOW_RATE", "0.05"))

jlog("INFO", "worker iniciado")
while True:
    item = r.blpop("orders", timeout=5)
    if not item:
        continue
    msg = json.loads(item[1])
    ctx = extract(msg.get("carrier", {}))
    started = time.time()
    with tracer.start_as_current_span("process_order", context=ctx, kind=trace.SpanKind.CONSUMER) as span:
        span.set_attribute("order.id", msg["id"])
        try:
            time.sleep(2.0 if random.random() < SLOW_RATE else random.uniform(0.05, 0.4))
            if random.random() < FAIL_RATE:
                raise RuntimeError("estoque indisponível")
            jlog("INFO", "pedido processado", order_id=msg["id"])
            processed.add(1, {"result": "ok"})
        except Exception as exc:  # noqa: BLE001
            span.record_exception(exc)
            span.set_status(trace.Status(trace.StatusCode.ERROR, str(exc)))
            jlog("ERROR", "falha ao processar o pedido", order_id=msg["id"], error=str(exc))
            processed.add(1, {"result": "error"})
        finally:
            duration.record(time.time() - started)
