"""store-service tests — pure helpers (build_product_detail, sku_valid),
catalog list/detail with a fake pool, graceful inventory degradation, and the
chaos gate. No real infra (fake asyncpg pool + respx-mocked inventory)."""

from __future__ import annotations

import httpx
import pytest
import respx
from fastapi.testclient import TestClient

from mesh_common import db

from store_service.app import Product, app, build_product_detail, sku_valid
from store_service import app as app_mod


# ── Pure helpers ──────────────────────────────────────────────────────────────

def test_build_product_detail_in_stock():
    p = Product(id=1, name="Bottle", sku="SKU-001", price=18.99)
    detail = build_product_detail(p, 42)
    assert detail == {"id": 1, "name": "Bottle", "sku": "SKU-001", "price": 18.99,
                      "availability": "in_stock", "stock": 42}


def test_build_product_detail_out_of_stock():
    p = Product(id=1, name="Bottle", sku="SKU-001", price=18.99)
    assert build_product_detail(p, 0)["availability"] == "out_of_stock"


def test_build_product_detail_unknown_omits_stock():
    p = Product(id=1, name="Bottle", sku="SKU-001", price=18.99)
    detail = build_product_detail(p, None)
    assert detail["availability"] == "unknown"
    assert "stock" not in detail


@pytest.mark.parametrize("sku,ok", [
    ("SKU-001", True), ("SKU-999", True), ("SKU-000", True),
    ("SKU-1", False), ("SKU-0001", False), ("sku-001", False),
    ("SKU-ABC", False), ("SKU-01A", False), ("", False),
])
def test_sku_valid(sku, ok):
    assert sku_valid(sku) is ok


# ── Fake pool ──────────────────────────────────────────────────────────────────

class FakePool:
    def __init__(self, products=None, fail=None):
        self.products = products or []  # list of dict rows
        self.fail = fail

    async def execute(self, *a):
        return "OK"

    async def fetchval(self, *a):
        return len(self.products)

    async def fetch(self, *a):
        if self.fail:
            raise self.fail
        return self.products

    async def fetchrow(self, query, product_id):
        if self.fail:
            raise self.fail
        for row in self.products:
            if row["id"] == product_id:
                return row
        return None


@pytest.fixture
def pool(monkeypatch):
    p = FakePool(products=[
        {"id": 1, "name": "Aerodynamic Water Bottle", "sku": "SKU-001", "price": 18.99},
        {"id": 2, "name": "Wireless Earbuds", "sku": "SKU-002", "price": 79.50},
    ])

    async def fake_pg_pool(_db):
        return p

    monkeypatch.setattr(db, "pg_pool", fake_pg_pool)
    monkeypatch.setattr(app_mod.db, "pg_pool", fake_pg_pool)
    return p


@pytest.fixture
def client(pool):
    with TestClient(app) as c:  # lifespan runs against the fake pool
        yield c


# ── Endpoint contracts ──────────────────────────────────────────────────────────

def test_health_not_gated():
    with TestClient(app) as c:
        assert c.get("/health").json() == {"status": "UP", "service": "store-service"}


def test_list_products(client):
    resp = client.get("/products")
    assert resp.status_code == 200
    assert [p["sku"] for p in resp.json()] == ["SKU-001", "SKU-002"]


@respx.mock
def test_product_detail_enriched_when_inventory_returns_stock(client):
    respx.get(f"{app_mod.INVENTORY_URL}/stock/SKU-001").mock(
        return_value=httpx.Response(200, json={"sku": "SKU-001", "stock": 50, "source": "db"})
    )
    resp = client.get("/products/1")
    assert resp.status_code == 200
    body = resp.json()
    assert body["availability"] == "in_stock"
    assert body["stock"] == 50


@respx.mock
def test_product_detail_graceful_degradation(client):
    respx.get(f"{app_mod.INVENTORY_URL}/stock/SKU-001").mock(side_effect=httpx.ConnectError("down"))
    resp = client.get("/products/1")
    assert resp.status_code == 200
    body = resp.json()
    assert body["availability"] == "unknown"
    assert "stock" not in body


def test_product_detail_404(client):
    assert client.get("/products/999").status_code == 404


def test_chaos_gate_on_products(monkeypatch, client):
    app_mod.chaos.error_rate = 1.0
    app_mod.chaos.error_until = 2**31
    try:
        resp = client.get("/products")
        assert resp.status_code == 502
        assert resp.json() == {"error": "chaos-injected", "status": 502}
    finally:
        app_mod.chaos.error_rate = 0.0
        app_mod.chaos.error_until = 0
