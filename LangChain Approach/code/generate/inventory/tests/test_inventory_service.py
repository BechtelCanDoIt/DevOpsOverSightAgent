"""inventory-service tests — pure can_reserve guard, cache read-through,
reserve decrement + cache refresh/invalidate, and error mappings. Fake asyncpg
pool + fake redis, no real infra."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from mesh_common import db

from inventory_service import app as app_mod
from inventory_service.app import app, can_reserve


# ── Pure guard ──────────────────────────────────────────────────────────────────

@pytest.mark.parametrize("current,qty,ok", [
    (100, 1, True), (100, 100, True), (100, 101, False),
    (5, 5, True), (5, 6, False), (0, 1, False),
    (100, 0, False), (100, -1, False),
])
def test_can_reserve(current, qty, ok):
    assert can_reserve(current, qty) is ok


# ── Fakes ──────────────────────────────────────────────────────────────────────

class FakePool:
    def __init__(self, stock: dict[str, int] | None = None, read_fail=None, update_fail=None):
        self.stock = dict(stock or {})
        self.read_fail = read_fail
        self.update_fail = update_fail

    async def execute(self, query, *args):
        if "UPDATE stock" in query:
            if self.update_fail:
                raise self.update_fail
            self.stock[args[1]] -= args[0]
        return "OK"

    async def fetchval(self, *a):
        return len(self.stock)

    async def fetchrow(self, query, sku):
        if self.read_fail:
            raise self.read_fail
        if sku not in self.stock:
            return None
        return {"qty": self.stock[sku]}


class FakeRedis:
    def __init__(self, data=None, get_fail=False, set_fail=False):
        self.data = dict(data or {})
        self.get_fail = get_fail
        self.set_fail = set_fail
        self.deleted: list[str] = []

    async def get(self, key):
        if self.get_fail:
            raise RuntimeError("redis get down")
        return self.data.get(key)

    async def set(self, key, value):
        if self.set_fail:
            raise RuntimeError("redis set down")
        self.data[key] = value

    async def delete(self, key):
        self.deleted.append(key)
        self.data.pop(key, None)


@pytest.fixture
def wire(monkeypatch):
    pool = FakePool(stock={"SKU-001": 100})
    redis = FakeRedis()

    async def fake_pg_pool(_db):
        return pool

    monkeypatch.setattr(app_mod.db, "pg_pool", fake_pg_pool)
    monkeypatch.setattr(app_mod, "_cache_ref", lambda: redis)
    return pool, redis


@pytest.fixture
def client():
    return TestClient(app)


# ── stock ─────────────────────────────────────────────────────────────────────

def test_health_not_gated(client):
    assert client.get("/health").json() == {"status": "UP", "service": "inventory-service"}


def test_stock_cache_hit(client, wire):
    pool, redis = wire
    redis.data["stock:SKU-001"] = "77"
    body = client.get("/stock/SKU-001").json()
    assert body == {"sku": "SKU-001", "qty": 77, "source": "cache"}


def test_stock_cache_miss_populates(client, wire):
    pool, redis = wire
    body = client.get("/stock/SKU-001").json()
    assert body == {"sku": "SKU-001", "qty": 100, "source": "db"}
    assert redis.data["stock:SKU-001"] == "100"  # populated on miss


def test_stock_unknown_404(client, wire):
    assert client.get("/stock/SKU-999").status_code == 404


def test_stock_db_read_failure_500(client, monkeypatch):
    pool = FakePool(read_fail=RuntimeError("boom"))

    async def fake_pg_pool(_db):
        return pool

    monkeypatch.setattr(app_mod.db, "pg_pool", fake_pg_pool)
    monkeypatch.setattr(app_mod, "_cache_ref", lambda: None)
    resp = client.get("/stock/SKU-001")
    assert resp.status_code == 500
    assert resp.json() == {"error": "db-read-failed", "sku": "SKU-001"}


# ── reserve ─────────────────────────────────────────────────────────────────────

def test_reserve_success_decrements_and_refreshes(client, wire):
    pool, redis = wire
    body = client.post("/reserve", json={"sku": "SKU-001", "qty": 30}).json()
    assert body == {"sku": "SKU-001", "reserved": True, "remaining": 70}
    assert pool.stock["SKU-001"] == 70
    assert redis.data["stock:SKU-001"] == "70"


def test_reserve_insufficient(client, wire):
    body = client.post("/reserve", json={"sku": "SKU-001", "qty": 500}).json()
    assert body == {"sku": "SKU-001", "reserved": False, "remaining": 100}


def test_reserve_unknown_sku_404(client, wire):
    assert client.post("/reserve", json={"sku": "SKU-999", "qty": 1}).status_code == 404


def test_reserve_cache_set_failure_invalidates(client, monkeypatch):
    pool = FakePool(stock={"SKU-001": 100})
    redis = FakeRedis(set_fail=True)

    async def fake_pg_pool(_db):
        return pool

    monkeypatch.setattr(app_mod.db, "pg_pool", fake_pg_pool)
    monkeypatch.setattr(app_mod, "_cache_ref", lambda: redis)
    resp = client.post("/reserve", json={"sku": "SKU-001", "qty": 10})
    assert resp.status_code == 201
    assert "stock:SKU-001" in redis.deleted  # invalidated after set error


def test_reserve_db_update_failure_500(client, monkeypatch):
    pool = FakePool(stock={"SKU-001": 100}, update_fail=RuntimeError("boom"))

    async def fake_pg_pool(_db):
        return pool

    monkeypatch.setattr(app_mod.db, "pg_pool", fake_pg_pool)
    monkeypatch.setattr(app_mod, "_cache_ref", lambda: None)
    resp = client.post("/reserve", json={"sku": "SKU-001", "qty": 10})
    assert resp.status_code == 500
    assert resp.json() == {"error": "db-update-failed", "sku": "SKU-001"}


def test_reserve_chaos_gate(client):
    app_mod.chaos.error_rate = 1.0
    app_mod.chaos.error_until = 2**31
    try:
        resp = client.post("/reserve", json={"sku": "SKU-001", "qty": 1})
        assert resp.status_code == 502
        assert resp.json() == {"error": "chaos-injected", "status": 502}
    finally:
        app_mod.chaos.error_rate = 0.0
        app_mod.chaos.error_until = 0
