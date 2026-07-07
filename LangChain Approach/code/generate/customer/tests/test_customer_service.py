"""customer-service tests — mirrors the Ballerina customer_service_test.bal
coverage (env_or, chaos auth, chaos_error_response, build_customer,
validate_new_customer, is_valid_customer_id) plus endpoint/seed/chaos-gate
contract tests with a fake asyncpg pool (no real infra).
"""

from __future__ import annotations

import json
import time

import pytest
from fastapi.testclient import TestClient

from mesh_common import ChaosState, build_chaos_app, chaos_error_response, env_or
from mesh_common import db

from customer_service import app as app_mod
from customer_service.app import (
    NewCustomer,
    SEED_CUSTOMERS,
    app,
    build_customer,
    is_valid_customer_id,
    validate_new_customer,
)


# ── Fake asyncpg pool ────────────────────────────────────────────────────────
class FakePool:
    """Just enough of the asyncpg pool surface used by app.py:
    execute / fetchval / fetchrow."""

    def __init__(self, customers: dict[int, tuple[str, str]] | None = None,
                 fail: Exception | None = None):
        self.customers = dict(customers or {})
        self.fail = fail
        self.executed: list[tuple[str, tuple]] = []

    def _next_id(self) -> int:
        return max(self.customers, default=0) + 1

    async def execute(self, query: str, *args):
        self.executed.append((query, args))
        if "INSERT INTO customers" in query:
            self.customers[self._next_id()] = (args[0], args[1])
        return "OK"

    async def fetchval(self, query: str, *args):
        self.executed.append((query, args))
        if "count(*)" in query:
            return len(self.customers)
        if "RETURNING id" in query:
            new_id = self._next_id()
            self.customers[new_id] = (args[0], args[1])
            return new_id
        raise AssertionError(f"unexpected fetchval: {query}")

    async def fetchrow(self, query: str, *args):
        if self.fail is not None:
            raise self.fail
        self.executed.append((query, args))
        row = self.customers.get(args[0])
        if row is None:
            return None
        return {"id": args[0], "name": row[0], "email": row[1]}


@pytest.fixture
def pool(monkeypatch) -> FakePool:
    fake = FakePool(customers={i + 1: c for i, c in enumerate(SEED_CUSTOMERS)})

    async def fake_pg_pool(default_db: str):
        assert default_db == "customerdb"
        return fake

    monkeypatch.setattr(db, "pg_pool", fake_pg_pool)
    return fake


@pytest.fixture(autouse=True)
def quiet_chaos():
    """Each test starts and ends with chaos off."""
    state = app_mod.chaos
    state.latency_ms = 0
    state.latency_until = 0
    state.error_rate = 0.0
    state.error_until = 0
    state.error_status = 502
    yield


client = TestClient(app)  # no `with`: lifespan (DB init) not triggered


# ── env_or ───────────────────────────────────────────────────────────────────
def test_env_or_fallback_when_unset(monkeypatch):
    monkeypatch.delenv("CUSTOMER_TEST_UNSET_VAR_XYZ", raising=False)
    assert env_or("CUSTOMER_TEST_UNSET_VAR_XYZ", "fallback-default") == "fallback-default"


def test_env_or_returns_value_when_set(monkeypatch):
    monkeypatch.setenv("CUSTOMER_TEST_SET_VAR_XYZ", "hello-env")
    assert env_or("CUSTOMER_TEST_SET_VAR_XYZ", "should-not-be-used") == "hello-env"


# ── chaos auth (port of chaosAuthed tests: exercised via the :9099 app) ──────
def test_chaos_authed_positive():
    expected = env_or("CHAOS_TOKEN", "dev-chaos-token")
    chaos_client = TestClient(build_chaos_app(ChaosState()))
    resp = chaos_client.post("/chaos/reset", headers={"X-Chaos-Token": expected})
    assert resp.status_code == 200
    assert resp.json() == {"status": "reset"}


def test_chaos_authed_negative():
    chaos_client = TestClient(build_chaos_app(ChaosState()))
    wrong = chaos_client.post("/chaos/reset", headers={"X-Chaos-Token": "definitely-not-the-token"})
    assert wrong.status_code == 403
    missing = chaos_client.post("/chaos/reset")  # nil token
    assert missing.status_code == 403


# ── chaos_error_response ─────────────────────────────────────────────────────
def test_chaos_error_response_status_and_payload():
    r = chaos_error_response(503)
    assert r.status_code == 503
    assert json.loads(r.body) == {"error": "chaos-injected", "status": 503}


# ── build_customer (response shape) ──────────────────────────────────────────
def test_build_customer_shape():
    payload = NewCustomer(name="Alice Johnson", email="alice@example.com")
    c = build_customer(42, payload)
    assert c["id"] == 42
    assert c["name"] == "Alice Johnson"
    assert c["email"] == "alice@example.com"


# ── validate_new_customer ────────────────────────────────────────────────────
def test_validate_new_customer_accepts():
    ok = NewCustomer(name="Bob Smith", email="bob@example.com")
    assert validate_new_customer(ok) is None


def test_validate_new_customer_rejects():
    blank_name = NewCustomer(name="   ", email="x@example.com")
    assert validate_new_customer(blank_name) is not None

    blank_email = NewCustomer(name="Eve", email="")
    assert validate_new_customer(blank_email) is not None

    no_at = NewCustomer(name="Dan", email="dan-at-example.com")
    assert validate_new_customer(no_at) is not None


# ── is_valid_customer_id ─────────────────────────────────────────────────────
def test_is_valid_customer_id():
    assert is_valid_customer_id(1)
    assert is_valid_customer_id(999)
    assert not is_valid_customer_id(0)
    assert not is_valid_customer_id(-1)


# ── endpoints ────────────────────────────────────────────────────────────────
def test_health_shape():
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "UP", "service": "customer-service"}


def test_health_never_chaos_gated():
    app_mod.chaos.error_rate = 1.0
    app_mod.chaos.error_until = int(time.time()) + 60
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "UP", "service": "customer-service"}


def test_create_customer(pool):
    resp = client.post("/customers", json={"name": "Frank Ocean", "email": "frank@example.com"})
    assert resp.status_code == 201
    assert resp.json() == {"id": 6, "name": "Frank Ocean", "email": "frank@example.com"}
    assert pool.customers[6] == ("Frank Ocean", "frank@example.com")


def test_get_customer_found(pool):
    resp = client.get("/customers/1")
    assert resp.status_code == 200
    assert resp.json() == {"id": 1, "name": "Alice Johnson", "email": "alice@example.com"}


def test_get_customer_not_found(pool):
    resp = client.get("/customers/999")
    assert resp.status_code == 404
    assert resp.content == b""  # http:NOT_FOUND — empty body


def test_get_customer_db_error_maps_to_500(monkeypatch):
    fake = FakePool(fail=RuntimeError("connection reset"))

    async def fake_pg_pool(default_db: str):
        return fake

    monkeypatch.setattr(db, "pg_pool", fake_pg_pool)
    resp = client.get("/customers/1")
    assert resp.status_code == 500


def test_chaos_gate_rejects_business_routes(pool):
    app_mod.chaos.error_rate = 1.0
    app_mod.chaos.error_status = 502
    app_mod.chaos.error_until = int(time.time()) + 60
    for resp in (
        client.post("/customers", json={"name": "X", "email": "x@example.com"}),
        client.get("/customers/1"),
    ):
        assert resp.status_code == 502
        assert resp.json() == {"error": "chaos-injected", "status": 502}
    assert pool.executed == []  # chaos short-circuits before any DB work


# ── startup seed behavior (port of init()) ──────────────────────────────────
def test_startup_seeds_when_empty(monkeypatch):
    fake = FakePool()  # count == 0

    async def fake_pg_pool(default_db: str):
        assert default_db == "customerdb"
        return fake

    monkeypatch.setattr(db, "pg_pool", fake_pg_pool)
    with TestClient(app):  # runs lifespan
        pass
    assert list(fake.customers.values()) == list(SEED_CUSTOMERS)
    assert fake.customers[1] == ("Alice Johnson", "alice@example.com")
    assert fake.customers[5] == ("Eve Park", "eve@example.com")
    create_stmts = [q for q, _ in fake.executed if "CREATE TABLE IF NOT EXISTS customers" in q]
    assert len(create_stmts) == 1


def test_startup_skips_seed_when_populated(monkeypatch):
    fake = FakePool(customers={i + 1: c for i, c in enumerate(SEED_CUSTOMERS)})

    async def fake_pg_pool(default_db: str):
        return fake

    monkeypatch.setattr(db, "pg_pool", fake_pg_pool)
    with TestClient(app):
        pass
    inserts = [q for q, _ in fake.executed if "INSERT INTO customers" in q]
    assert inserts == []


def test_startup_survives_db_down(monkeypatch):
    async def fake_pg_pool(default_db: str):
        raise ConnectionError("postgres is not up yet")

    monkeypatch.setattr(db, "pg_pool", fake_pg_pool)
    with TestClient(app) as c:  # must not raise — warn-and-continue
        assert c.get("/health").status_code == 200
