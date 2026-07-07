"""inventory-service — FastAPI port of the Ballerina ``inventory.bal``.

GET  /stock/{sku}   -> {sku, qty, source: "cache"|"db"}   Redis read-through:
                       cache first, fall back to Postgres on miss and populate
                       the cache (the cold-cache story).
POST /reserve       -> {sku, reserved, remaining}          availability check
                       (cache then db), pure ``can_reserve`` guard, Postgres
                       decrement is authoritative, cache refreshed after the
                       decrement (invalidated if the refresh errors).

Status/body contract matches the Ballerina source exactly: 404 (empty body)
for an unknown SKU, 500 {"error": "db-read-failed"|"db-update-failed", sku},
503 {"error": "db-unavailable", sku}, and — like Ballerina POST resources —
/reserve answers 201 Created on the normal path (including reserved=false).
"""

from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel

from mesh_common import ChaosState, apply_chaos, chaos_error_response, log_error, log_info
from mesh_common import db

chaos = ChaosState()

SEED_SKUS = ["SKU-001", "SKU-002", "SKU-003", "SKU-004", "SKU-005"]


# ── Domain types ──────────────────────────────────────────────────────────────

class ReserveReq(BaseModel):
    sku: str
    qty: int


def cache_key(sku: str) -> str:
    return f"stock:{sku}"


def can_reserve(current: int, qty: int) -> bool:
    """Pure reservation guard — true iff ``qty`` units can be reserved against
    ``current`` on-hand. Rejects non-positive requests and any draw that would
    go negative."""
    return qty > 0 and current >= qty


# ── Startup: schema + seed ────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(_app: FastAPI):
    """Best-effort schema init + seed; warn-and-continue when the DB is still
    starting (load-bearing for compose start ordering)."""
    try:
        pool = await db.pg_pool("inventorydb")
        await pool.execute("CREATE TABLE IF NOT EXISTS stock (sku TEXT PRIMARY KEY, qty INT)")
        count = await pool.fetchval("SELECT COUNT(*) FROM stock")
        if count == 0:
            for sku in SEED_SKUS:
                await pool.execute(
                    "INSERT INTO stock (sku, qty) VALUES ($1, $2) ON CONFLICT (sku) DO NOTHING",
                    sku, 100,
                )
            log_info("seeded stock table with SKU-001..SKU-005")
        log_info("inventory-service started")
    except Exception as e:
        log_error("DB unavailable at startup — schema init skipped", e)
    yield


app = FastAPI(title="inventory-service", lifespan=lifespan)


# ── Data-layer helpers ────────────────────────────────────────────────────────

def _cache_ref():
    """Redis client or None — mirrors Ballerina's ``cache is redis:Client``
    guard (a client-init failure silently degrades to no-cache)."""
    try:
        return db.redis_client()
    except Exception:
        return None


async def db_qty(sku: str) -> int | None:
    """Read qty from Postgres; None when the SKU is unknown. Errors propagate."""
    pool = await db.pg_pool("inventorydb")
    row = await pool.fetchrow("SELECT qty FROM stock WHERE sku = $1", sku)
    return None if row is None else row["qty"]


# ── Service ───────────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    return {"status": "UP", "service": "inventory-service"}


@app.get("/stock/{sku}")
async def get_stock(sku: str):
    injected = await apply_chaos(chaos)
    if injected is not None:
        return chaos_error_response(injected)

    # Cache lookup (graceful on Redis errors or unavailability → treat as miss).
    cache = _cache_ref()
    cached = None
    if cache is not None:
        try:
            cached = await cache.get(cache_key(sku))
        except Exception as e:
            log_error(f"redis get failed for sku={sku}, falling back to db", e)
            cached = None
    if cached is not None:
        try:
            qty = int(cached)
        except (TypeError, ValueError):
            qty = None
        if qty is not None:
            log_info(f"stock hit cache sku={sku}")
            return {"sku": sku, "qty": qty, "source": "cache"}

    # Cache miss → Postgres.
    try:
        qty = await db_qty(sku)
    except Exception as e:
        log_error(f"db read failed for sku={sku}", e)
        return JSONResponse(status_code=500, content={"error": "db-read-failed", "sku": sku})
    if qty is None:
        return Response(status_code=404)

    # Populate cache for next time (best-effort).
    if cache is not None:
        try:
            await cache.set(cache_key(sku), str(qty))
        except Exception as e:
            log_error(f"redis set failed for sku={sku}", e)
    log_info(f"stock miss db sku={sku}")
    return {"sku": sku, "qty": qty, "source": "db"}


@app.post("/reserve", status_code=201)
async def reserve(req: ReserveReq):
    injected = await apply_chaos(chaos)
    if injected is not None:
        return chaos_error_response(injected)

    # Determine current available qty: cache first, then db.
    cache = _cache_ref()
    from_cache = None
    if cache is not None:
        cached = None
        try:
            cached = await cache.get(cache_key(req.sku))
        except Exception as e:
            log_error(f"redis get failed for sku={req.sku}, falling back to db", e)
        if cached is not None:
            try:
                from_cache = int(cached)
            except (TypeError, ValueError):
                from_cache = None

    if from_cache is not None:
        current = from_cache
    else:
        try:
            db_val = await db_qty(req.sku)
        except Exception as e:
            log_error(f"db read failed for sku={req.sku}", e)
            return JSONResponse(status_code=500, content={"error": "db-read-failed", "sku": req.sku})
        if db_val is None:
            return Response(status_code=404)
        current = db_val

    if not can_reserve(current, req.qty):
        log_info(f"reserve denied sku={req.sku} want={req.qty} have={current}")
        return {"sku": req.sku, "reserved": False, "remaining": current}

    # Decrement in Postgres (authoritative).
    try:
        pool = await db.pg_pool("inventorydb")
    except Exception as e:
        log_error(f"db unavailable for sku={req.sku}", e)
        return JSONResponse(status_code=503, content={"error": "db-unavailable", "sku": req.sku})
    try:
        await pool.execute("UPDATE stock SET qty = qty - $1 WHERE sku = $2", req.qty, req.sku)
    except Exception as e:
        log_error(f"reserve db update failed for sku={req.sku}", e)
        return JSONResponse(status_code=500, content={"error": "db-update-failed", "sku": req.sku})

    remaining = current - req.qty

    # Refresh the cache entry with the new value (best-effort; on error invalidate).
    if cache is not None:
        try:
            await cache.set(cache_key(req.sku), str(remaining))
        except Exception as e:
            log_error(f"redis update failed for sku={req.sku}, invalidating", e)
            try:
                await cache.delete(cache_key(req.sku))
            except Exception as e2:
                log_error(f"redis invalidate failed for sku={req.sku}", e2)

    log_info(f"reserved sku={req.sku} qty={req.qty} remaining={remaining}")
    return {"sku": req.sku, "reserved": True, "remaining": remaining}


if __name__ == "__main__":
    from mesh_common.runner import run

    run(app, "inventory-service", "devopspoc/inventory", chaos)
