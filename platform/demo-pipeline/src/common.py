import json
import sys
from opentelemetry import trace


def jlog(level, msg, **fields):
    """Uma linha JSON por evento, com trace_id e span_id para o Loki correlacionar com o Tempo."""
    ctx = trace.get_current_span().get_span_context()
    rec = {"level": level, "msg": msg}
    if ctx.is_valid:
        rec["trace_id"] = format(ctx.trace_id, "032x")
        rec["span_id"] = format(ctx.span_id, "016x")
    rec.update(fields)
    print(json.dumps(rec, ensure_ascii=False), file=sys.stdout, flush=True)
