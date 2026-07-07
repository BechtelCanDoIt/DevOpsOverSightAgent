"""store-service — FastAPI port of the Ballerina store ``service.bal``.

GET /products        -> list the catalog (from storedb).
GET /products/{id}   -> product detail, enriched with live stock from
                        inventory-service. Graceful degradation: on any
                        inventory error the product is still returned with
                        ``availability="unknown"`` and ``stock`` omitted.

Faithful-port note: the Ballerina ``fetchStock`` reads the ``stock`` field off
inventory-service's response (``resp?.stock``). inventory-service actually
returns ``qty``, so in the reference the enrichment degrades to "unknown"
unless a ``stock`` field is present. We preserve that exact read.
"""

from __future__ import annotations

from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from mesh_common import ChaosState, apply_chaos, chaos_error_response, env_or, log_error, log_info
from mesh_common import db

chaos = ChaosState()

INVENTORY_URL = env_or("INVENTORY_URL", "http://inventory-service:9090")

# Seed catalog — SKUs line up with inventory-service's seeded stock.
SEED_PRODUCTS = [
    {"name": "Aerodynamic Water Bottle", "sku": "SKU-001", "price": 18.99},
    {"name": "Wireless Earbuds", "sku": "SKU-002", "price": 79.50},
    {"name": "Trail Running Shoes", "sku": "SKU-003", "price": 124.00},
    {"name": "Insulated Travel Mug", "sku": "SKU-004", "price": 24.95},
    {"name": "Merino Wool Socks", "sku": "SKU-005", "price": 16.00},
]


class Product(BaseModel):
    id: int
    name: str
    sku: str
    price: float


# ── Pure helpers (unit-tested without DB or HTTP) ──────────────────────────────

def build_product_detail(product: Product, stock: int | None) -> dict:
    """Combine a product row with the (optional) live stock count into the
    externally-shaped ProductDetail. ``stock`` is omitted when unknown."""
    if stock is not None:
        availability = "in_stock" if stock > 0 else "out_of_stock"
    else:
        availability = "unknown"
    detail: dict = {
        "id": product.id,
        "name": product.name,
        "sku": product.sku,
        "price": product.price,
        "availability": availability,
    }
    if stock is not None:
        detail["stock"] = stock
    return detail


def sku_valid(sku: str) -> bool:
    """Validate a SKU against the seeded pattern SKU-NNN (three ASCII digits) —
    equivalent to /^SKU-\\d{3}$/."""
    if len(sku) != 7 or not sku.startswith("SKU-"):
        return False
    digits = sku[4:]
    if not digits.isdigit():
        return False
    value = int(digits)
    return 0 <= value <= 999


# ── Best-effort downstream lookup ──────────────────────────────────────────────

async def fetch_stock(sku: str) -> int | None:
    """Live stock from inventory-service, or None when the call fails (caller
    degrades gracefully). Reads the ``stock`` field, matching the reference."""
    try:
        async with httpx.AsyncClient(timeout=5) as client:
            resp = await client.get(f"{INVENTORY_URL}/stock/{sku}")
            resp.raise_for_status()
            return resp.json().get("stock")
    except Exception as e:
        log_error("inventory stock lookup failed; degrading to unknown availability", e)
        return None


# ── Startup: schema + seed ─────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(_app: FastAPI):
    try:
        pool = await db.pg_pool("storedb")
        await pool.execute(
            "CREATE TABLE IF NOT EXISTS products "
            "(id SERIAL PRIMARY KEY, name TEXT, sku TEXT, price NUMERIC)"
        )
        count = await pool.fetchval("SELECT count(*) FROM products")
        if count == 0:
            for p in SEED_PRODUCTS:
                await pool.execute(
                    "INSERT INTO products (name, sku, price) VALUES ($1, $2, $3)",
                    p["name"], p["sku"], p["price"],
                )
            log_info("seeded products table")
        log_info("store-service started")
    except Exception as e:
        log_error("DB unavailable at startup — schema init skipped", e)
    yield


app = FastAPI(title="store-service", lifespan=lifespan)


@app.get("/health")
async def health():
    return {"status": "UP", "service": "store-service"}


@app.get("/products")
async def list_products():
    injected = await apply_chaos(chaos)
    if injected is not None:
        return chaos_error_response(injected)
    try:
        pool = await db.pg_pool("storedb")
        rows = await pool.fetch("SELECT id, name, sku, price FROM products ORDER BY id")
    except Exception as e:
        log_error("product list failed", e)
        return JSONResponse(status_code=500, content={"error": "db-read-failed"})
    log_info("listed catalog products")
    return [
        {"id": r["id"], "name": r["name"], "sku": r["sku"], "price": float(r["price"])}
        for r in rows
    ]


@app.get("/products/{product_id}")
async def get_product(product_id: int):
    injected = await apply_chaos(chaos)
    if injected is not None:
        return chaos_error_response(injected)
    try:
        pool = await db.pg_pool("storedb")
        row = await pool.fetchrow(
            "SELECT id, name, sku, price FROM products WHERE id = $1", product_id
        )
    except Exception as e:
        log_error("product lookup failed", e)
        return JSONResponse(status_code=500, content={"error": "db-read-failed"})
    if row is None:
        log_info("product not found")
        return Response(status_code=404)

    product = Product(id=row["id"], name=row["name"], sku=row["sku"], price=float(row["price"]))
    stock = await fetch_stock(product.sku)  # cross-service call → child span
    log_info("fetched product detail")
    return build_product_detail(product, stock)


if __name__ == "__main__":
    from mesh_common.runner import run

    run(app, "store-service", "devopspoc/store", chaos)
