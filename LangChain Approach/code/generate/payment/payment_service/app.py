"""payment-service — FastAPI port of the Ballerina payment service (main.bal).

Stateless, no database, no downstream calls. POST /charge runs the chaos gate
FIRST (payment-service is the headline chaos-demo target), then an in-process
mock bank authorization that always approves.
"""

from __future__ import annotations

import uuid

from fastapi import FastAPI
from pydantic import BaseModel

from mesh_common import ChaosState, apply_chaos, chaos_error_response, log_error, log_info

chaos = ChaosState()

app = FastAPI(title="payment-service", docs_url=None, redoc_url=None, openapi_url=None)


# ---- Request / response shapes ----


class ChargeRequest(BaseModel):
    amount: float
    currency: str = "USD"
    orderId: str


class ChargeResponse(BaseModel):
    paymentId: str
    status: str
    amount: float
    authId: str
    note: str


# ---- In-process mock bank (no real I/O, no downstream, no DB) ----


class BankAuthorization(BaseModel):
    authId: str
    approved: bool
    note: str


def _uuid_str() -> str:
    """36-char hyphenated UUID, same string shape as Ballerina's uuid:createType1AsString().

    Deliberate deviation: uuid4 (random) instead of type 1 — no MAC/timestamp
    leak — while keeping the 8-4-4-4-12 hex shape the ID contract expects.
    """
    h = uuid.uuid4().hex
    return f"{h[0:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}"


def mock_bank_authorize(amount: float, currency: str) -> BankAuthorization:
    """Simulates a bank authorization response — a dummy approval with a
    generated auth id. No external call, no database."""
    return BankAuthorization(
        authId="AUTH-" + _uuid_str(),
        approved=True,
        note=f"mock-bank approved {currency} {amount} (simulated)",
    )


# ---- Services ----


@app.get("/health")
async def health() -> dict:
    return {"status": "UP", "service": "payment-service"}


@app.post("/charge", status_code=201)
async def charge(req: ChargeRequest):
    # Chaos gate first — payment-service is the headline demo target.
    injected = await apply_chaos(chaos)
    if injected is not None:
        log_error(f"charge rejected by chaos for order {req.orderId} (status {injected})")
        return chaos_error_response(injected)

    auth = mock_bank_authorize(req.amount, req.currency)
    payment_id = "PAY-" + _uuid_str()

    log_info("charge processed",
             order_id=req.orderId, payment_id=payment_id,
             amount=req.amount, currency=req.currency, auth_id=auth.authId)

    return ChargeResponse(
        paymentId=payment_id,
        status="approved" if auth.approved else "declined",
        amount=req.amount,
        authId=auth.authId,
        note=auth.note,
    )


if __name__ == "__main__":
    from mesh_common.runner import run

    run(app, "payment-service", "devopspoc/payment", chaos)
