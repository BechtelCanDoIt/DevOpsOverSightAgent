"""payment-service tests — mirrors the Ballerina payment_service_test.bal intent
(env_or, chaos auth, chaos_error_response shape, mock bank, ChargeRequest
defaults) plus endpoint tests for /health and /charge. The chaos-gate test is
the headline: payment-service is the demo's chaos target.

No real infra: payment is stateless (no DB/Redis/NATS), so plain TestClient.
"""

from __future__ import annotations

import re
import time

import pytest
from fastapi.testclient import TestClient
from mesh_common import ChaosState, build_chaos_app, chaos_error_response, env_or

from payment_service.app import ChargeRequest, app, chaos, mock_bank_authorize

client = TestClient(app)

UUID_SHAPE = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"


@pytest.fixture(autouse=True)
def _reset_chaos():
    """Leave the module-level chaos state clean after every test."""
    yield
    chaos.latency_ms = 0
    chaos.latency_until = 0
    chaos.error_rate = 0.0
    chaos.error_until = 0
    chaos.error_status = 502


def _inject_error(status: int = 502, rate: float = 1.0) -> None:
    chaos.error_rate = rate
    chaos.error_status = status
    chaos.error_until = int(time.time()) + 60


# ---------------------------------------------------------------------------
# obs — env_or (mirrors testEnvOrReturnsFallbackWhenUnset / ...EnvValueWhenSet)
# ---------------------------------------------------------------------------


def test_env_or_returns_fallback_when_unset():
    assert env_or("PAYMENT_TEST_DEFINITELY_UNSET_VAR_XYZ", "fallback-value") == "fallback-value"


def test_env_or_returns_env_value_when_set(monkeypatch):
    monkeypatch.setenv("PAYMENT_TEST_ENVOR_SET_VAR", "from-env")
    assert env_or("PAYMENT_TEST_ENVOR_SET_VAR", "fallback-value") == "from-env"


# ---------------------------------------------------------------------------
# chaos — token auth (mirrors testChaosAuthedRejectsBadToken / ...AcceptsConfiguredToken)
# The Python kit gates inside the chaos app, so we assert through its endpoints.
# ---------------------------------------------------------------------------


def test_chaos_endpoints_reject_bad_token():
    chaos_client = TestClient(build_chaos_app(ChaosState()))
    # nil token
    assert chaos_client.post("/chaos/reset").status_code == 403
    # empty token
    assert chaos_client.post("/chaos/reset", headers={"X-Chaos-Token": ""}).status_code == 403
    # wrong token
    assert chaos_client.post(
        "/chaos/reset", headers={"X-Chaos-Token": "wrong-token"}).status_code == 403


def test_chaos_endpoints_accept_configured_token():
    expected = env_or("CHAOS_TOKEN", "dev-chaos-token")
    chaos_client = TestClient(build_chaos_app(ChaosState()))
    r = chaos_client.post("/chaos/reset", headers={"X-Chaos-Token": expected})
    assert r.status_code == 200
    assert r.json() == {"status": "reset"}


# ---------------------------------------------------------------------------
# chaos — chaos_error_response (mirrors testChaosErrorResponseShape / ...ArbitraryStatus)
# ---------------------------------------------------------------------------


def test_chaos_error_response_shape():
    import json

    r = chaos_error_response(503)
    assert r.status_code == 503
    payload = json.loads(r.body)
    assert payload["error"] == "chaos-injected"
    assert payload["status"] == 503


def test_chaos_error_response_propagates_arbitrary_status():
    import json

    r = chaos_error_response(418)
    assert r.status_code == 418
    assert json.loads(r.body)["status"] == 418


# ---------------------------------------------------------------------------
# mock_bank_authorize (mirrors testMockBankAuthorizeApprovesAndShapesNote / ...UniqueAuthIds)
# ---------------------------------------------------------------------------


def test_mock_bank_authorize_approves_and_shapes_note():
    auth = mock_bank_authorize(42.0, "USD")
    assert auth.approved, "mock bank must approve in this POC"
    assert auth.authId.startswith("AUTH-"), f"authId should be prefixed with AUTH-, got: {auth.authId}"
    assert "USD" in auth.note, f"note should mention the currency, got: {auth.note}"
    assert "mock-bank approved" in auth.note, \
        f"note should describe the mock bank approval, got: {auth.note}"


def test_mock_bank_authorize_produces_unique_auth_ids():
    a = mock_bank_authorize(1.00, "USD")
    b = mock_bank_authorize(1.00, "USD")
    assert a.authId != b.authId, "successive calls must yield distinct auth ids"


# ---------------------------------------------------------------------------
# ChargeRequest defaults (mirrors testChargeRequestDefaultsCurrencyToUsd)
# ---------------------------------------------------------------------------


def test_charge_request_defaults_currency_to_usd():
    req = ChargeRequest(amount=10.00, orderId="ORD-1")
    assert req.currency == "USD", "ChargeRequest.currency must default to USD when omitted"


# ---------------------------------------------------------------------------
# endpoints — /health
# ---------------------------------------------------------------------------


def test_health_shape():
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "UP", "service": "payment-service"}


def test_health_is_never_chaos_gated():
    _inject_error(status=502, rate=1.0)
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "UP", "service": "payment-service"}


# ---------------------------------------------------------------------------
# endpoints — POST /charge happy path
# ---------------------------------------------------------------------------


def test_charge_happy_path_shape():
    r = client.post("/charge", json={"amount": 42.5, "currency": "USD", "orderId": "ORD-1"})
    assert r.status_code == 201  # POST-create parity with the Ballerina stack (and invoice/inventory)
    body = r.json()
    assert set(body.keys()) == {"paymentId", "status", "amount", "authId", "note"}
    assert body["status"] == "approved"
    assert body["amount"] == 42.5
    assert re.fullmatch(f"PAY-{UUID_SHAPE}", body["paymentId"]), body["paymentId"]
    assert re.fullmatch(f"AUTH-{UUID_SHAPE}", body["authId"]), body["authId"]
    assert "mock-bank approved" in body["note"] and "USD" in body["note"]


def test_charge_defaults_currency_when_omitted():
    r = client.post("/charge", json={"amount": 10.0, "orderId": "ORD-2"})
    assert r.status_code == 201
    assert "USD" in r.json()["note"]


def test_charge_mints_distinct_payment_ids():
    ids = {client.post("/charge", json={"amount": 1.0, "orderId": "ORD-3"}).json()["paymentId"]
           for _ in range(3)}
    assert len(ids) == 3


def test_charge_rejects_missing_order_id():
    # FastAPI validation deviation: Ballerina payload binding returns 400,
    # FastAPI returns 422. The rejection itself is the contract being tested.
    r = client.post("/charge", json={"amount": 10.0})
    assert r.status_code == 422


# ---------------------------------------------------------------------------
# endpoints — POST /charge chaos gate (the headline demo behavior)
# ---------------------------------------------------------------------------


def test_charge_chaos_gate_injects_error(caplog):
    _inject_error(status=502, rate=1.0)
    r = client.post("/charge", json={"amount": 42.5, "orderId": "ORD-99"})
    assert r.status_code == 502
    assert r.json() == {"error": "chaos-injected", "status": 502}
    # Exact Ballerina rejection log text — the Splunk-correlation contract.
    assert any(rec.getMessage() == "charge rejected by chaos for order ORD-99 (status 502)"
               for rec in caplog.records)


def test_charge_chaos_gate_propagates_configured_status():
    _inject_error(status=503, rate=1.0)
    r = client.post("/charge", json={"amount": 1.0, "orderId": "ORD-100"})
    assert r.status_code == 503
    assert r.json() == {"error": "chaos-injected", "status": 503}


def test_charge_recovers_after_chaos_window_reset():
    _inject_error(status=502, rate=1.0)
    chaos.error_rate = 0.0
    chaos.error_until = 0
    r = client.post("/charge", json={"amount": 5.0, "orderId": "ORD-101"})
    assert r.status_code == 201
    assert r.json()["status"] == "approved"
