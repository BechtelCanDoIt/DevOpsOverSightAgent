"""order-service tests — the checkout saga and its error mappings.

Covers new_order_id shape, the full happy path (200 confirmed + NATS envelope
with traceparent), and every failure branch (400 invalid customer, 409
insufficient stock, 502 payment, 502 billing, 500 persist, 503 db-down) with
respx-mocked downstreams and a fake NATS connection. No real infra.
"""

from __future__ import annotations

import json
import re

import httpx
import pytest
import respx
from fastapi.testclient import TestClient

from mesh_common import db

from order_service import app as app_mod
from order_service.app import UNIT_PRICE, app, new_order_id

C = app_mod.CUSTOMER_URL
INV = app_mod.INVENTORY_URL
PAY = app_mod.PAYMENT_URL
INVOICE = app_mod.INVOICE_URL

ORDER = {"customerId": 1, "items": [{"sku": "SKU-001", "qty": 2}]}


class FakeNats:
    def __init__(self, fail=False):
        self.fail = fail
        self.published: list[tuple[str, bytes]] = []
        self.is_closed = False

    async def publish(self, subject, payload):
        if self.fail:
            raise RuntimeError("nats down")
        self.published.append((subject, payload))


class FakePool:
    def __init__(self, execute_fail=None):
        self.execute_fail = execute_fail
        self.inserts: list[tuple] = []

    async def execute(self, query, *args):
        if "INSERT INTO orders" in query and self.execute_fail:
            raise self.execute_fail
        if "INSERT INTO orders" in query:
            self.inserts.append(args)
        return "OK"


@pytest.fixture
def nats(monkeypatch):
    fake = FakeNats()

    async def fake_conn():
        return fake

    monkeypatch.setattr(db, "nats_connection", fake_conn)
    monkeypatch.setattr(app_mod.db, "nats_connection", fake_conn)
    return fake


@pytest.fixture
def pool(monkeypatch):
    fake = FakePool()

    async def fake_pg_pool(_db):
        return fake

    monkeypatch.setattr(db, "pg_pool", fake_pg_pool)
    monkeypatch.setattr(app_mod.db, "pg_pool", fake_pg_pool)
    return fake


@pytest.fixture
def client():
    return TestClient(app)


def _happy_downstreams():
    respx.get(re.compile(rf"{re.escape(C)}/customers/\d+")).mock(return_value=httpx.Response(200, json={"id": 1}))
    respx.post(f"{INV}/reserve").mock(return_value=httpx.Response(201, json={"sku": "SKU-001", "reserved": True, "remaining": 98}))
    respx.post(f"{PAY}/charge").mock(return_value=httpx.Response(200, json={"paymentId": "PAY-x", "status": "approved"}))
    respx.post(f"{INVOICE}/invoices").mock(return_value=httpx.Response(201, json={"invoiceId": 1, "status": "issued"}))


# ── order id ──────────────────────────────────────────────────────────────────

def test_new_order_id_shape():
    assert re.fullmatch(r"ORD-\d+-\d{4}", new_order_id())


# ── happy path ──────────────────────────────────────────────────────────────────

@respx.mock
def test_happy_path_confirmed(client, pool, nats):
    _happy_downstreams()
    resp = client.post("/orders", json=ORDER)
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "confirmed"
    assert body["total"] == round(UNIT_PRICE * 2, 2)
    assert body["orderId"].startswith("ORD-")
    assert len(pool.inserts) == 1


@respx.mock
def test_happy_path_publishes_traceparent_envelope(client, pool, nats, monkeypatch):
    # OTel is disabled in tests, so there is no active span — inject known ids
    # to assert the envelope-building contract (the async trace-join carrier).
    tid, sid = "abc123def456789012345678deadbeef", "1234567890abcdef"
    monkeypatch.setattr(app_mod, "span_ctx", lambda: (tid, sid))
    _happy_downstreams()
    client.post("/orders", json=ORDER)
    assert len(nats.published) == 1
    subject, payload = nats.published[0]
    assert subject == "orders.created"
    envelope = json.loads(payload)
    assert set(envelope) == {"orderId", "customerId", "total", "traceparent"}
    assert envelope["traceparent"] == f"00-{tid}-{sid}-01"


@respx.mock
def test_nats_publish_failure_is_non_fatal(client, pool, monkeypatch):
    _happy_downstreams()
    fail_nats = FakeNats(fail=True)

    async def conn():
        return fail_nats

    monkeypatch.setattr(app_mod.db, "nats_connection", conn)
    resp = client.post("/orders", json=ORDER)
    assert resp.status_code == 200  # order still confirmed


# ── error mappings ──────────────────────────────────────────────────────────────

@respx.mock
def test_invalid_customer_404_maps_400(client, pool, nats):
    respx.get(re.compile(rf"{re.escape(C)}/customers/\d+")).mock(return_value=httpx.Response(404))
    resp = client.post("/orders", json=ORDER)
    assert resp.status_code == 400
    assert resp.json() == {"error": "invalid customer"}


@respx.mock
def test_customer_call_error_maps_400(client, pool, nats):
    respx.get(re.compile(rf"{re.escape(C)}/customers/\d+")).mock(side_effect=httpx.ConnectError("down"))
    resp = client.post("/orders", json=ORDER)
    assert resp.status_code == 400


@respx.mock
def test_insufficient_stock_409(client, pool, nats):
    respx.get(re.compile(rf"{re.escape(C)}/customers/\d+")).mock(return_value=httpx.Response(200, json={"id": 1}))
    respx.post(f"{INV}/reserve").mock(return_value=httpx.Response(201, json={"sku": "SKU-001", "reserved": False, "remaining": 0}))
    resp = client.post("/orders", json=ORDER)
    assert resp.status_code == 409
    assert resp.json() == {"error": "insufficient stock"}


@respx.mock
def test_reserve_call_error_409(client, pool, nats):
    respx.get(re.compile(rf"{re.escape(C)}/customers/\d+")).mock(return_value=httpx.Response(200, json={"id": 1}))
    respx.post(f"{INV}/reserve").mock(side_effect=httpx.ConnectError("down"))
    resp = client.post("/orders", json=ORDER)
    assert resp.status_code == 409
    assert resp.json() == {"error": "stock reservation failed"}


@respx.mock
def test_payment_non_2xx_maps_502(client, pool, nats):
    respx.get(re.compile(rf"{re.escape(C)}/customers/\d+")).mock(return_value=httpx.Response(200, json={"id": 1}))
    respx.post(f"{INV}/reserve").mock(return_value=httpx.Response(201, json={"reserved": True}))
    respx.post(f"{PAY}/charge").mock(return_value=httpx.Response(502, json={"error": "chaos-injected", "status": 502}))
    resp = client.post("/orders", json=ORDER)
    assert resp.status_code == 502
    assert resp.json() == {"error": "payment failed"}


@respx.mock
def test_billing_non_2xx_maps_502(client, pool, nats):
    respx.get(re.compile(rf"{re.escape(C)}/customers/\d+")).mock(return_value=httpx.Response(200, json={"id": 1}))
    respx.post(f"{INV}/reserve").mock(return_value=httpx.Response(201, json={"reserved": True}))
    respx.post(f"{PAY}/charge").mock(return_value=httpx.Response(200, json={"status": "approved"}))
    respx.post(f"{INVOICE}/invoices").mock(return_value=httpx.Response(500))
    resp = client.post("/orders", json=ORDER)
    assert resp.status_code == 502
    assert resp.json() == {"error": "billing failed"}


@respx.mock
def test_persist_error_maps_500(client, monkeypatch, nats):
    _happy_downstreams()
    fake = FakePool(execute_fail=RuntimeError("constraint"))

    async def fake_pg_pool(_db):
        return fake

    monkeypatch.setattr(app_mod.db, "pg_pool", fake_pg_pool)
    resp = client.post("/orders", json=ORDER)
    assert resp.status_code == 500
    assert resp.json() == {"error": "order persist failed"}


@respx.mock
def test_db_unavailable_maps_503(client, monkeypatch, nats):
    _happy_downstreams()

    async def broken_pool(_db):
        raise RuntimeError("cannot connect")

    monkeypatch.setattr(app_mod.db, "pg_pool", broken_pool)
    resp = client.post("/orders", json=ORDER)
    assert resp.status_code == 503
    assert resp.json() == {"error": "db unavailable"}


def test_chaos_gate_first(client):
    app_mod.chaos.error_rate = 1.0
    app_mod.chaos.error_until = 2**31
    try:
        resp = client.post("/orders", json=ORDER)
        assert resp.status_code == 502
        assert resp.json() == {"error": "chaos-injected", "status": 502}
    finally:
        app_mod.chaos.error_rate = 0.0
        app_mod.chaos.error_until = 0
