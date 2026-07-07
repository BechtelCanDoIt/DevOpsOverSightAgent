"""notification-service — FastAPI port of the Ballerina notification service.

notification-service is an async consumer: /health is the ONLY HTTP route —
there are no business HTTP endpoints. On startup it subscribes to the NATS
subject `orders.created` (best-effort with retry — a broker outage must never
crash the service; this mirrors the Ballerina init() that degrades to a
warning when NATS is unreachable).

The message handler parses the W3C `traceparent` carried in the order event
envelope (NATS does not auto-propagate OTel context) and logs
"notification sent" with the PARSED trace_id/span_id passed explicitly —
that log line is the Splunk async-leg join, the correlation contract for the
whole mesh.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging

from contextlib import asynccontextmanager

from fastapi import FastAPI
from pydantic import BaseModel, ConfigDict

from mesh_common import ChaosState, apply_chaos, log_error, log_info, parse_traceparent, span_ctx
from mesh_common import db

chaos = ChaosState()

# NATS subject published by order-service (CONVENTIONS.md envelope contract).
NATS_SUBJECT = "orders.created"

# Best-effort startup retry — the Ballerina init() tries once and warns; here
# we retry briefly (compose start ordering) before degrading with the same
# warning. Module-level so tests can shrink them.
RETRY_ATTEMPTS = 5
RETRY_DELAY_S = 2.0

_logger = logging.getLogger("devopspoc")


def _log_warn(msg: str, error: BaseException | str | None = None, **fields) -> None:
    """Warn-level structured log (mesh_common only ships info/error helpers)."""
    tid, sid = span_ctx()
    extra: dict = {"trace_id": tid, "span_id": sid, **fields}
    if error is not None:
        extra["error"] = str(error)
    _logger.warning(msg, extra=extra)


class OrderEvent(BaseModel):
    """Order event envelope published by order-service to `orders.created`.

    `traceparent` is W3C trace-context, carrying the order's trace so this
    async leg joins the same trace in Splunk.

    customerId is typed str (matching the Ballerina OrderEvent record) but
    order-service publishes it as an int; coerce_numbers_to_str mirrors
    Ballerina's cloneWithType numeric→string coercion so real order events
    parse cleanly.
    """

    model_config = ConfigDict(coerce_numbers_to_str=True)

    orderId: str
    customerId: str
    total: float
    traceparent: str


async def handle_order_event(message) -> None:
    """NATS `orders.created` handler — factored out so tests can call it
    directly with fake messages (anything exposing `.data` bytes).

    NEVER raises: a malformed envelope is logged and skipped so one bad
    message cannot crash the subscriber.
    """
    injected = await apply_chaos(chaos)
    if injected is not None:
        log_error(f"order event dropped by chaos (status {injected})")
        return

    raw = ""
    try:
        raw = message.data.decode("utf-8")
        payload = json.loads(raw)
        event = OrderEvent.model_validate(payload)

        tid, sid = parse_traceparent(event.traceparent)
        if tid == "":
            log_error(f"bad traceparent in order event: {event.traceparent}")
            return

        # Explicit trace_id/span_id override the auto-injected (empty) ones —
        # this line is the Splunk async-leg join. Do not rename these fields.
        log_info("notification sent", trace_id=tid, span_id=sid, order_id=event.orderId)
    except Exception as e:
        log_error(f"failed to process order event: {raw}", e)


async def start_consumer():
    """Subscribe to `orders.created`; returns the subscription or None.

    Best-effort: connection failures degrade to a warning (same text as the
    Ballerina init()) rather than crashing the process.
    """
    last_err: BaseException | None = None
    for attempt in range(RETRY_ATTEMPTS):
        try:
            nc = await db.nats_connection()
            return await nc.subscribe(NATS_SUBJECT, cb=handle_order_event)
        except Exception as e:
            last_err = e
            if attempt < RETRY_ATTEMPTS - 1:
                await asyncio.sleep(RETRY_DELAY_S)
    _log_warn("NATS broker unreachable — order event consumer not started", error=last_err)
    return None


@asynccontextmanager
async def lifespan(_app: FastAPI):
    # Background task so /health comes up immediately while NATS may still be
    # starting (load-bearing for compose start ordering).
    consumer_task = asyncio.create_task(start_consumer())
    try:
        yield
    finally:
        subscription = None
        if consumer_task.done():
            if not consumer_task.cancelled() and consumer_task.exception() is None:
                subscription = consumer_task.result()
        else:
            consumer_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await consumer_task
        if subscription is not None:
            with contextlib.suppress(Exception):
                await subscription.unsubscribe()


app = FastAPI(title="notification-service", lifespan=lifespan,
              docs_url=None, redoc_url=None, openapi_url=None)


@app.get("/health")
async def health() -> dict:
    return {"status": "UP", "service": "notification-service"}


if __name__ == "__main__":
    from mesh_common.runner import run

    run(app, "notification-service", "devopspoc/notification", chaos)
