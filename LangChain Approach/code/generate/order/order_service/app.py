"""order-service — FastAPI port of the Ballerina ``order_service.bal``.

The mesh orchestrator and the most correlation-critical service. POST /orders
runs the checkout saga in a fixed sequence, each step mapping downstream
failures to a specific status:

    a. validate customer   GET  {CUSTOMER_URL}/customers/{id}   404/err -> 400
    b. reserve each item   POST {INVENTORY_URL}/reserve         reserved:false/err -> 409
    c. charge payment      POST {PAYMENT_URL}/charge            non-2xx/err -> 502 "payment failed"
    d. bill invoice        POST {INVOICE_URL}/invoices          non-2xx/err -> 502 "billing failed"
    e. persist order       INSERT INTO orders                   db err -> 500, db down -> 503
    f. publish NATS        orders.created + traceparent          NON-fatal (log + continue)

The NATS envelope carries a W3C ``traceparent`` so notification-service's async
leg joins the same trace in Splunk. Log message texts match the reference
exactly ("payment failed", "order confirmed", ...) — they are the Splunk
correlation contract.
"""

from __future__ import annotations

import json
import random
import time
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from mesh_common import (
    ChaosState,
    apply_chaos,
    build_traceparent,
    chaos_error_response,
    env_or,
    log_error,
    log_info,
)
from mesh_common import db
from mesh_common.obs import span_ctx

chaos = ChaosState()

UNIT_PRICE = 19.99  # fixed demo unit price per item (USD); total = sum(qty) * UNIT_PRICE
ORDERS_SUBJECT = "orders.created"

CUSTOMER_URL = env_or("CUSTOMER_URL", "http://customer-service:9090")
INVENTORY_URL = env_or("INVENTORY_URL", "http://inventory-service:9090")
PAYMENT_URL = env_or("PAYMENT_URL", "http://payment-service:9090")
INVOICE_URL = env_or("INVOICE_URL", "http://invoice-service:9090")


class OrderItem(BaseModel):
    sku: str
    qty: int


class OrderRequest(BaseModel):
    customerId: int
    items: list[OrderItem]


def new_order_id() -> str:
    """ORD-{epoch millis}-{random 4-digit suffix}."""
    millis = int(time.time() * 1000)
    suffix = random.randint(1000, 9999)
    return f"ORD-{millis}-{suffix}"


def _error(status: int, message: str) -> JSONResponse:
    return JSONResponse(status_code=status, content={"error": message})


async def _publish_order_created(order_id: str, customer_id: int, total: float) -> None:
    """Publish orders.created with a W3C traceparent envelope (order -> notification)."""
    tid, sid = span_ctx()
    envelope = {
        "orderId": order_id,
        "customerId": customer_id,
        "total": total,
        "traceparent": build_traceparent(tid, sid),
    }
    nc = await db.nats_connection()
    await nc.publish(ORDERS_SUBJECT, json.dumps(envelope).encode("utf-8"))


@asynccontextmanager
async def lifespan(_app: FastAPI):
    try:
        pool = await db.pg_pool("orderdb")
        await pool.execute(
            "CREATE TABLE IF NOT EXISTS orders "
            "(id TEXT PRIMARY KEY, customer_id INT, total NUMERIC, status TEXT)"
        )
        log_info("order-service initialized")
    except Exception as e:
        log_error("DB unavailable at startup — schema init skipped", e)
    yield


app = FastAPI(title="order-service", lifespan=lifespan)


@app.get("/health")
async def health():
    return {"status": "UP", "service": "order-service"}


@app.post("/orders")
async def create_order(req: OrderRequest):
    injected = await apply_chaos(chaos)
    if injected is not None:
        return chaos_error_response(injected)

    order_id = new_order_id()
    log_info("order received", order_id=order_id, customer_id=req.customerId)

    async with httpx.AsyncClient(timeout=10) as client:
        # a. Validate customer.
        try:
            cust = await client.get(f"{CUSTOMER_URL}/customers/{req.customerId}")
        except Exception as e:
            log_error("customer validation call failed", e, order_id=order_id)
            return _error(400, "invalid customer")
        if cust.status_code != 200:
            log_error("invalid customer", order_id=order_id,
                      customer_id=req.customerId, status=cust.status_code)
            return _error(400, "invalid customer")
        log_info("customer validated", order_id=order_id, customer_id=req.customerId)

        # b. Reserve stock per item.
        total = 0.0
        for item in req.items:
            try:
                reserved = await client.post(
                    f"{INVENTORY_URL}/reserve", json={"sku": item.sku, "qty": item.qty}
                )
            except Exception as e:
                log_error("stock reservation call failed", e, order_id=order_id)
                return _error(409, "stock reservation failed")
            body = {}
            try:
                body = reserved.json()
            except Exception:
                body = {}
            if reserved.status_code >= 300 or not body.get("reserved", False):
                log_error("stock not available", order_id=order_id, sku=item.sku, qty=item.qty)
                return _error(409, "insufficient stock")
            total += UNIT_PRICE * item.qty
        total = round(total, 2)
        log_info("stock reserved", order_id=order_id, total=total)

        # c. Charge payment — the headline failure path.
        try:
            charge = await client.post(
                f"{PAYMENT_URL}/charge",
                json={"amount": total, "currency": "USD", "orderId": order_id},
            )
        except Exception as e:
            log_error("payment failed", e, order_id=order_id, total=total)
            return _error(502, "payment failed")
        if not (200 <= charge.status_code < 300):
            log_error("payment failed", order_id=order_id, total=total, status=charge.status_code)
            return _error(502, "payment failed")
        log_info("payment charged", order_id=order_id, total=total)

        # d. Bill invoice.
        try:
            inv = await client.post(
                f"{INVOICE_URL}/invoices", json={"orderId": order_id, "amount": total}
            )
        except Exception as e:
            log_error("billing failed", e, order_id=order_id)
            return _error(502, "billing failed")
        if not (200 <= inv.status_code < 300):
            log_error("billing failed", order_id=order_id, status=inv.status_code)
            return _error(502, "billing failed")
        log_info("invoice created", order_id=order_id)

    # e. Persist the order.
    try:
        pool = await db.pg_pool("orderdb")
    except Exception as e:
        log_error("db unavailable", e, order_id=order_id)
        return _error(503, "db unavailable")
    try:
        await pool.execute(
            "INSERT INTO orders (id, customer_id, total, status) VALUES ($1, $2, $3, $4)",
            order_id, req.customerId, total, "confirmed",
        )
    except Exception as e:
        log_error("order persist failed", e, order_id=order_id)
        return _error(500, "order persist failed")
    log_info("order persisted", order_id=order_id)

    # f. Publish to NATS (non-fatal).
    try:
        await _publish_order_created(order_id, req.customerId, total)
        log_info("order event published", order_id=order_id, subject=ORDERS_SUBJECT)
    except Exception as e:
        log_error("order event publish failed", e, order_id=order_id)

    log_info("order confirmed", order_id=order_id, status="confirmed", total=total)
    return {"orderId": order_id, "status": "confirmed", "total": total}


if __name__ == "__main__":
    from mesh_common.runner import run

    run(app, "order-service", "devopspoc/order", chaos)
