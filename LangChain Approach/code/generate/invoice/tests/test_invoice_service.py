"""invoice-service tests — pure helpers (validate_new_invoice, row_to_invoice,
affected_rows), the issued->paid state machine, and error mappings. Fake
asyncpg pool, no real infra."""

from __future__ import annotations

from decimal import Decimal

import pytest
from fastapi.testclient import TestClient

from mesh_common import db

from invoice_service import app as app_mod
from invoice_service.app import (
    NewInvoice,
    affected_rows,
    app,
    new_issued_invoice,
    row_to_invoice,
    validate_new_invoice,
)


# ── Pure helpers ──────────────────────────────────────────────────────────────

def test_validate_new_invoice_ok():
    assert validate_new_invoice(NewInvoice(orderId="ORD-1", amount=Decimal("10"))) is None


def test_validate_new_invoice_empty_order():
    assert validate_new_invoice(NewInvoice(orderId="  ", amount=Decimal("10"))) == "orderId must not be empty"


def test_validate_new_invoice_nonpositive():
    assert validate_new_invoice(NewInvoice(orderId="ORD-1", amount=Decimal("0"))) == "amount must be positive"


def test_row_to_invoice_shape():
    row = {"id": 7, "order_id": "ORD-9", "amount": Decimal("39.98"), "status": "issued"}
    assert row_to_invoice(row) == {"invoiceId": 7, "orderId": "ORD-9", "amount": 39.98, "status": "issued"}


def test_new_issued_invoice():
    inv = new_issued_invoice(3, NewInvoice(orderId="ORD-2", amount=Decimal("5")))
    assert inv == {"invoiceId": 3, "orderId": "ORD-2", "amount": 5.0, "status": "issued"}


@pytest.mark.parametrize("tag,n", [("UPDATE 1", 1), ("UPDATE 0", 0), ("INSERT 0 1", 1), ("", 0), ("garbage", 0)])
def test_affected_rows(tag, n):
    assert affected_rows(tag) == n


# ── Fake pool + state machine ───────────────────────────────────────────────────

class FakePool:
    def __init__(self):
        self.invoices: dict[int, dict] = {}
        self._next = 1

    async def execute(self, query, *args):
        if "CREATE TABLE" in query:
            return "OK"
        if "UPDATE invoices SET status = 'paid'" in query:
            inv_id = args[0]
            if inv_id in self.invoices:
                self.invoices[inv_id]["status"] = "paid"
                return "UPDATE 1"
            return "UPDATE 0"
        return "OK"

    async def fetchval(self, query, *args):
        if "INSERT INTO invoices" in query:
            inv_id = self._next
            self._next += 1
            self.invoices[inv_id] = {"id": inv_id, "order_id": args[0], "amount": args[1], "status": "issued"}
            return inv_id
        raise AssertionError(query)

    async def fetchrow(self, query, inv_id):
        return self.invoices.get(inv_id)


@pytest.fixture
def client(monkeypatch):
    pool = FakePool()

    async def fake_pg_pool(_db):
        return pool

    monkeypatch.setattr(app_mod.db, "pg_pool", fake_pg_pool)
    with TestClient(app) as c:
        yield c


def test_health_not_gated(client):
    assert client.get("/health").json() == {"status": "UP", "service": "invoice-service"}


def test_create_invoice_issued(client):
    resp = client.post("/invoices", json={"orderId": "ORD-1", "amount": 39.98})
    assert resp.status_code == 201
    body = resp.json()
    assert body["orderId"] == "ORD-1"
    assert body["status"] == "issued"
    assert body["invoiceId"] == 1


def test_get_invoice_roundtrip(client):
    created = client.post("/invoices", json={"orderId": "ORD-1", "amount": 39.98}).json()
    got = client.get(f"/invoices/{created['invoiceId']}")
    assert got.status_code == 200
    assert got.json()["status"] == "issued"


def test_get_invoice_404(client):
    assert client.get("/invoices/999").status_code == 404


def test_pay_invoice_transitions_to_paid(client):
    created = client.post("/invoices", json={"orderId": "ORD-1", "amount": 39.98}).json()
    paid = client.post(f"/invoices/{created['invoiceId']}/pay")
    assert paid.status_code == 201
    assert paid.json()["status"] == "paid"


def test_pay_unknown_invoice_404(client):
    assert client.post("/invoices/999/pay").status_code == 404


def test_create_invoice_validation_500(client):
    resp = client.post("/invoices", json={"orderId": "", "amount": 10})
    assert resp.status_code == 500
    assert resp.text == "orderId must not be empty"


def test_chaos_gate(client):
    app_mod.chaos.error_rate = 1.0
    app_mod.chaos.error_until = 2**31
    try:
        resp = client.post("/invoices", json={"orderId": "ORD-1", "amount": 10})
        assert resp.status_code == 502
        assert resp.json() == {"error": "chaos-injected", "status": 502}
    finally:
        app_mod.chaos.error_rate = 0.0
        app_mod.chaos.error_until = 0
