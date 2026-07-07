"""load-gen — a long-lived worker (not a service) that drives the five
front-facing domains so the observability stack always has something to show.
payment + notification are exercised transitively through order.

Pattern is chosen via ``--pattern <name>`` (CLI) or LOADGEN_PATTERN env, default
"baseline"; the named patterns/<name>.yaml defines RPS, worker count, optional
spike window, and per-domain weights. Each HTTP call becomes an OTel span (via
the httpx auto-instrumentation), so the generated load is visible in Datadog.

Port of the Ballerina worker (``MCP Best Practices Approach/code/generate/
load-gen/main.bal``): same env var names/defaults, same pacing math, same log
message texts and fields.
"""

from __future__ import annotations

import asyncio
import random
import sys
import time
from decimal import ROUND_FLOOR, Decimal
from pathlib import Path

import httpx
import yaml
from pydantic import BaseModel, ConfigDict, Field

from mesh_common import env_or, log_error, log_info

# ── Pattern model (camelCase YAML keys preserved via aliases) ─────────────────


class Spike(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    after_seconds: int = Field(alias="afterSeconds")
    rps: int
    for_seconds: int = Field(alias="forSeconds")


class Weights(BaseModel):
    store: int
    customer: int
    inventory: int
    invoice: int
    order: int


class Pattern(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    name: str
    base_rps: int = Field(alias="baseRps")
    workers: int
    duration_seconds: int = Field(alias="durationSeconds")
    spike: Spike | None = None
    weights: Weights


# ── Downstream front-doors ────────────────────────────────────────────────────
# Same env names/defaults as the Ballerina `final http:Client`s. The shared
# httpx client is created lazily so it picks up the OTel httpx instrumentation
# installed by init_telemetry() in the __main__ block.

STORE_URL = env_or("STORE_URL", "http://store:9090")
CUSTOMER_URL = env_or("CUSTOMER_URL", "http://customer:9090")
ORDER_URL = env_or("ORDER_URL", "http://order:9090")
INVENTORY_URL = env_or("INVENTORY_URL", "http://inventory:9090")
INVOICE_URL = env_or("INVOICE_URL", "http://invoice:9090")

_client: httpx.AsyncClient | None = None


def http_client() -> httpx.AsyncClient:
    global _client
    if _client is None:
        # 30s matches the Ballerina http:Client default timeout.
        _client = httpx.AsyncClient(timeout=30.0)
    return _client


# ── Entry point ───────────────────────────────────────────────────────────────


async def main(args: list[str]) -> None:
    pattern_name = select_pattern(args)
    p = load_pattern(pattern_name)
    log_info("load-gen starting", pattern=p.name, baseRps=p.base_rps,
             workers=p.workers, durationSeconds=p.duration_seconds)

    start_sec = int(time.time())
    tasks = [asyncio.create_task(worker_loop(p, start_sec, w)) for w in range(p.workers)]
    await asyncio.gather(*tasks)


async def worker_loop(p: Pattern, start_sec: int, worker_id: int) -> None:
    while True:
        elapsed = int(time.time()) - start_sec
        if p.duration_seconds > 0 and elapsed >= p.duration_seconds:
            return
        rps = current_rps(p, elapsed)
        await run_flow(p)
        # Pace so all `workers` tasks together approximate `rps` req/s.
        interval = p.workers / rps if rps > 0 else 1.0
        await asyncio.sleep(interval)


def current_rps(p: Pattern, elapsed_s: int) -> int:
    """RPS schedule: spike.rps inside [afterSeconds, afterSeconds+forSeconds), else baseRps."""
    s = p.spike
    if s is not None and s.after_seconds <= elapsed_s < s.after_seconds + s.for_seconds:
        return s.rps
    return p.base_rps


async def run_flow(p: Pattern) -> None:
    domain = pick_domain(p.weights)
    try:
        if domain == "store":
            await store_flow()
        elif domain == "customer":
            await customer_flow()
        elif domain == "inventory":
            await inventory_flow()
        elif domain == "invoice":
            await invoice_flow()
        elif domain == "order":
            await order_flow()
    except Exception as e:
        # Services may be mid-startup or chaos may be injected; keep driving.
        log_error("flow failed: " + domain, error=e)


# ── Per-domain flows ──────────────────────────────────────────────────────────
# Like the Ballerina `check client->get(...)` with an http:Response target,
# only transport-level failures raise — 4xx/5xx responses are ignored noise.


async def store_flow() -> None:
    await http_client().get(f"{STORE_URL}/products")
    await http_client().get(f"{STORE_URL}/products/{rand_int(1, 5)}")


async def customer_flow() -> None:
    if random.random() < 0.3:
        n = rand_int(1, 100000)
        payload = {"name": f"user-{n}", "email": f"user-{n}@example.com"}
        await http_client().post(f"{CUSTOMER_URL}/customers", json=payload)
    else:
        await http_client().get(f"{CUSTOMER_URL}/customers/{rand_int(1, 5)}")


async def inventory_flow() -> None:
    await http_client().get(f"{INVENTORY_URL}/stock/{rand_sku()}")


async def invoice_flow() -> None:
    # Early on these may 404 (no invoices yet) — realistic read noise.
    await http_client().get(f"{INVOICE_URL}/invoices/{rand_int(1, 5)}")


async def order_flow() -> None:
    payload = {
        "customerId": rand_int(1, 5),
        "items": [{"sku": rand_sku(), "qty": rand_int(1, 3)}],
    }
    await http_client().post(f"{ORDER_URL}/orders", json=payload)


# ── Helpers ───────────────────────────────────────────────────────────────────


def pick_domain(w: Weights) -> str:
    return pick_domain_at(w, random.random())


def pick_domain_at(w: Weights, r: float) -> str:
    """Pure, deterministic weighted-domain selection. ``r`` must be in [0.0, 1.0).

    Extracted from `pick_domain` so unit tests can pin a specific roll. The roll
    is computed in Decimal (via the float's shortest repr) to mirror Ballerina's
    exact `decimal` arithmetic — e.g. r=0.70, total=100 must land on roll 70,
    not float 69.999…'s floor of 69.
    """
    entries = [
        ("store", w.store),
        ("customer", w.customer),
        ("inventory", w.inventory),
        ("invoice", w.invoice),
        ("order", w.order),
    ]
    total = sum(wt for _, wt in entries)
    if total <= 0:
        return "store"
    # Map r ∈ [0.0, 1.0) to an index in [0, total), flooring before int-cast.
    roll = int((Decimal(str(r)) * total).to_integral_value(rounding=ROUND_FLOOR))
    acc = 0
    for domain_name, wt in entries:
        acc += wt
        if roll < acc:
            return domain_name
    return "store"


def rand_int(lo: int, hi: int) -> int:
    """Inclusive random int in [lo, hi] (Ballerina randInt parity)."""
    return random.randint(lo, hi)


def rand_sku() -> str:
    return f"SKU-00{rand_int(1, 5)}"


def select_pattern(args: list[str]) -> str:
    i = 0
    while i < len(args):
        if args[i] == "--pattern" and i + 1 < len(args):
            return args[i + 1]
        i += 1
    return env_or("LOADGEN_PATTERN", "baseline")


def load_pattern(name: str) -> Pattern:
    """Read patterns/<name>.yaml — cwd-relative like the Ballerina worker, with
    a fallback to the patterns/ dir shipped next to this package."""
    candidates = [
        Path("patterns") / f"{name}.yaml",
        Path(__file__).resolve().parent.parent / "patterns" / f"{name}.yaml",
    ]
    for path in candidates:
        if path.is_file():
            return Pattern.model_validate(yaml.safe_load(path.read_text()))
    raise FileNotFoundError(f"patterns/{name}.yaml")


if __name__ == "__main__":
    # Worker process — no HTTP listeners, so no mesh_common.runner. Boot the
    # telemetry + JSON logging directly, then drive traffic forever.
    from mesh_common.obs import setup_logging
    from mesh_common.telemetry import init_telemetry

    init_telemetry("load-gen")
    setup_logging("devopspoc/load-gen")
    asyncio.run(main(sys.argv[1:]))
