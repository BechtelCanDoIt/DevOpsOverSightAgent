"""customer-service — FastAPI port of the Ballerina customer service.

Source of truth: `MCP Best Practices Approach/code/generate/customer/service.bal`.
Endpoint paths, response field names, status-code mappings, seed data, and log
message texts match the Ballerina source exactly (they are the Splunk
correlation contract).
"""

from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.responses import PlainTextResponse, Response
from pydantic import BaseModel

from mesh_common import ChaosState, apply_chaos, chaos_error_response, log_error, log_info
from mesh_common import db

chaos = ChaosState()

DEFAULT_DB = "customerdb"

# Seed ~5 customers (ids 1..5) when the table is empty, so order-service's
# varied customerIds resolve. Names/emails copied verbatim from service.bal.
SEED_CUSTOMERS: list[tuple[str, str]] = [
    ("Alice Johnson", "alice@example.com"),
    ("Bob Smith", "bob@example.com"),
    ("Carol Diaz", "carol@example.com"),
    ("Dan Wright", "dan@example.com"),
    ("Eve Park", "eve@example.com"),
]


# ---- Data types (Ballerina closed records) ----
class NewCustomer(BaseModel):
    model_config = {"extra": "forbid"}

    name: str
    email: str


# ---- Pure helpers (unit-testable; no DB) — ports of the .bal helpers ----
def build_customer(id: int, payload: NewCustomer) -> dict:
    """Build a Customer response record from a generated id + the inbound payload."""
    return {"id": id, "name": payload.name, "email": payload.email}


def validate_new_customer(payload: NewCustomer) -> str | None:
    """Lightweight validation for inbound customer payloads. Returns a string
    describing the first problem found, or None when the payload is acceptable.
    (Kept defensive but loose: real schema validation is at the DB/JSON binding.)
    """
    if payload.name.strip() == "":
        return "customer name must be non-empty"
    if payload.email.strip() == "":
        return "customer email must be non-empty"
    if "@" not in payload.email:
        return "customer email must contain '@'"
    return None


def is_valid_customer_id(id: int) -> bool:
    """Validate a path-supplied customer id (route accepts int, but we still gate
    on positivity for defensive logging / future-proofing against route changes)."""
    return id > 0


# ---- Startup: ensure the schema exists and seed when empty (port of init()) ----
@asynccontextmanager
async def lifespan(app: FastAPI):
    try:
        pool = await db.pg_pool(DEFAULT_DB)
        await pool.execute(
            """CREATE TABLE IF NOT EXISTS customers (
            id SERIAL PRIMARY KEY,
            name TEXT,
            email TEXT
        )"""
        )
        count = await pool.fetchval("SELECT count(*) FROM customers")
        if count == 0:
            for name, email in SEED_CUSTOMERS:
                await pool.execute("INSERT INTO customers (name, email) VALUES ($1, $2)", name, email)
            log_info("seeded customers table")
        log_info("customer-service started")
    except Exception as e:
        # Warn-and-continue: load-bearing for compose start ordering.
        log_error("DB unavailable at startup — schema init skipped", e)
    yield


app = FastAPI(title="customer-service", lifespan=lifespan)


# ---- Health (NEVER chaos-gated) ----
@app.get("/health")
async def health():
    return {"status": "UP", "service": "customer-service"}


# ---- Business routes ----
@app.post("/customers", status_code=201)
async def create_customer(payload: NewCustomer):
    """Create a customer profile. (Ballerina post resources default to 201 Created.)"""
    injected = await apply_chaos(chaos)
    if injected is not None:
        return chaos_error_response(injected)
    pool = await db.pg_pool(DEFAULT_DB)
    id = await pool.fetchval(
        "INSERT INTO customers (name, email) VALUES ($1, $2) RETURNING id",
        payload.name,
        payload.email,
    )
    log_info("created customer")
    return {"id": id, "name": payload.name, "email": payload.email}


@app.get("/customers/{id}")
async def get_customer(id: int):
    """Look up a customer; 404 when missing (order-service validation depends on this)."""
    injected = await apply_chaos(chaos)
    if injected is not None:
        return chaos_error_response(injected)
    pool = await db.pg_pool(DEFAULT_DB)
    try:
        row = await pool.fetchrow("SELECT id, name, email FROM customers WHERE id = $1", id)
    except Exception as e:
        log_error("customer lookup failed", e)
        return PlainTextResponse(str(e), status_code=500)
    if row is None:
        log_info("customer not found")
        return Response(status_code=404)
    log_info("fetched customer")
    return {"id": row["id"], "name": row["name"], "email": row["email"]}


if __name__ == "__main__":
    from mesh_common.runner import run

    run(app, "customer-service", "devopspoc/customer", chaos)
