"""invoice-service — FastAPI port of the Ballerina invoice service (service.bal).

Wire contract (identical to the Ballerina source):
  POST /invoices            {orderId, amount} -> 201 Invoice (status "issued")
  GET  /invoices/{id}       -> 200 Invoice | 404 (empty body)
  POST /invoices/{id}/pay   -> 201 Invoice (status "paid") | 404 (empty body)
  GET  /health              -> {"status": "UP", "service": "invoice-service"}  (never chaos-gated)

Validation failures and DB errors surface as HTTP 500 with the error message as
a text/plain body — the Ballerina listener's default mapping for a resource
returning `error` (via `check`). Successful POST resources return 201 Created,
Ballerina's default status for POST resources returning a payload.
"""

from __future__ import annotations

from contextlib import asynccontextmanager
from decimal import Decimal

from fastapi import FastAPI
from fastapi.responses import JSONResponse, PlainTextResponse, Response
from pydantic import BaseModel

from mesh_common import ChaosState, apply_chaos, chaos_error_response, log_error, log_info
from mesh_common import db

chaos = ChaosState()

DEFAULT_DB = "invoicedb"

CREATE_TABLE = """CREATE TABLE IF NOT EXISTS invoices (
    id SERIAL PRIMARY KEY,
    order_id TEXT,
    amount NUMERIC,
    status TEXT
)"""

SELECT_INVOICE = "SELECT id, order_id, amount, status FROM invoices WHERE id = $1"


class NewInvoice(BaseModel):
    """Request body for invoice creation (order-service posts this during checkout)."""

    orderId: str
    amount: Decimal


# Pure helpers (kept module-level for unit testing).


def validate_new_invoice(req: NewInvoice) -> str | None:
    """Validate a NewInvoice request body: orderId must be non-empty and amount > 0.

    Returns a human-readable reason when invalid, None when valid (the port of
    the Ballerina `returns error?` signature).
    """
    if req.orderId.strip() == "":
        return "orderId must not be empty"
    if req.amount <= 0:
        return "amount must be positive"
    return None


def row_to_invoice(row) -> dict:
    """Map a stored Postgres row into the wire-shape Invoice returned to callers."""
    return {
        "invoiceId": row["id"],
        "orderId": row["order_id"],
        "amount": float(row["amount"]),
        "status": row["status"],
    }


def new_issued_invoice(invoice_id: int, req: NewInvoice) -> dict:
    """Build the wire-shape Invoice for a freshly-issued invoice."""
    return {
        "invoiceId": invoice_id,
        "orderId": req.orderId,
        "amount": float(req.amount),
        "status": "issued",
    }


def affected_rows(command_tag: str) -> int:
    """Row count from an asyncpg command tag (e.g. "UPDATE 1") — the port of
    sql:ExecutionResult.affectedRowCount (missing/garbled tag counts as 0)."""
    parts = command_tag.split()
    return int(parts[-1]) if parts and parts[-1].isdigit() else 0


@asynccontextmanager
async def lifespan(_app: FastAPI):
    # Create the table on startup (idempotent). Warn-and-continue when the DB
    # is still starting — load-bearing for compose start ordering.
    try:
        pool = await db.pg_pool(DEFAULT_DB)
        await pool.execute(CREATE_TABLE)
        log_info("invoice-service schema ready")
    except Exception as e:
        log_error("DB unavailable at startup — schema init skipped", e)
    yield


app = FastAPI(title="invoice-service", lifespan=lifespan,
              docs_url=None, redoc_url=None, openapi_url=None)


@app.get("/health")
async def health() -> dict:
    return {"status": "UP", "service": "invoice-service"}


@app.post("/invoices")
async def create_invoice(req: NewInvoice):
    """Create an invoice (called by order-service during checkout)."""
    injected = await apply_chaos(chaos)
    if injected is not None:
        return chaos_error_response(injected)
    reason = validate_new_invoice(req)
    if reason is not None:
        return PlainTextResponse(reason, status_code=500)
    try:
        pool = await db.pg_pool(DEFAULT_DB)
        invoice_id = await pool.fetchval(
            "INSERT INTO invoices (order_id, amount, status) VALUES ($1, $2, 'issued') RETURNING id",
            req.orderId, req.amount)
    except Exception as e:
        return PlainTextResponse(str(e), status_code=500)
    log_info(f"invoice issued: {invoice_id} for order {req.orderId}")
    return JSONResponse(status_code=201, content=new_issued_invoice(invoice_id, req))


@app.get("/invoices/{id}")
async def get_invoice(id: int):
    """Fetch a single invoice, or 404."""
    injected = await apply_chaos(chaos)
    if injected is not None:
        return chaos_error_response(injected)
    try:
        pool = await db.pg_pool(DEFAULT_DB)
        row = await pool.fetchrow(SELECT_INVOICE, id)
    except Exception as e:
        return PlainTextResponse(str(e), status_code=500)
    if row is None:
        log_info(f"invoice not found: {id}")
        return Response(status_code=404)
    return row_to_invoice(row)


@app.post("/invoices/{id}/pay")
async def pay_invoice(id: int):
    """Mark an invoice paid; returns the updated invoice (404 if absent)."""
    injected = await apply_chaos(chaos)
    if injected is not None:
        return chaos_error_response(injected)
    try:
        pool = await db.pg_pool(DEFAULT_DB)
        result = await pool.execute("UPDATE invoices SET status = 'paid' WHERE id = $1", id)
        if affected_rows(result) == 0:
            log_info(f"invoice not found for pay: {id}")
            return Response(status_code=404)
        row = await pool.fetchrow(SELECT_INVOICE, id)
    except Exception as e:
        return PlainTextResponse(str(e), status_code=500)
    if row is None:
        # Parity with Ballerina's sql:NoRowsError surfacing through `check` as a 500.
        return PlainTextResponse("Query did not retrieve any rows.", status_code=500)
    log_info(f"invoice paid: {id}")
    return JSONResponse(status_code=201, content=row_to_invoice(row))


if __name__ == "__main__":
    from mesh_common.runner import run

    run(app, "invoice-service", "devopspoc/invoice", chaos)
