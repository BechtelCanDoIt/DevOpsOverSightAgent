"""Chaos kit contract tests — mirrors the Ballerina chaos.bal test coverage."""

import time

import pytest
from fastapi.testclient import TestClient

from mesh_common.chaos import ChaosState, apply_chaos, build_chaos_app, chaos_error_response

TOKEN = {"X-Chaos-Token": "test-token"}


def make_client(state: ChaosState) -> TestClient:
    return TestClient(build_chaos_app(state, token="test-token"))


def test_latency_injection_sets_window():
    state = ChaosState()
    client = make_client(state)
    resp = client.post("/chaos/latency", json={"ms": 250, "duration_s": 120}, headers=TOKEN)
    assert resp.status_code == 200
    assert resp.json() == {"status": "latency injected", "ms": 250, "duration_s": 120}
    assert state.latency_ms == 250
    assert state.latency_until > int(time.time()) + 100


def test_error_injection_defaults():
    state = ChaosState()
    client = make_client(state)
    resp = client.post("/chaos/error", json={"rate": 0.8}, headers=TOKEN)
    assert resp.json() == {"status": "error injected", "rate": 0.8, "errorStatus": 502}
    assert state.error_status == 502
    assert state.error_until > int(time.time())


def test_reset_clears_state():
    state = ChaosState(latency_ms=100, latency_until=2**31, error_rate=1.0, error_until=2**31)
    client = make_client(state)
    resp = client.post("/chaos/reset", headers=TOKEN)
    assert resp.json() == {"status": "reset"}
    assert state.latency_ms == 0 and state.latency_until == 0
    assert state.error_rate == 0.0 and state.error_until == 0


def test_bad_token_forbidden():
    state = ChaosState()
    client = make_client(state)
    for path, body in [("/chaos/latency", {"ms": 1}), ("/chaos/error", {"rate": 1.0}), ("/chaos/reset", None)]:
        resp = client.post(path, json=body, headers={"X-Chaos-Token": "wrong"})
        assert resp.status_code == 403
    assert state.latency_ms == 0 and state.error_rate == 0.0


def test_missing_token_forbidden():
    state = ChaosState()
    client = make_client(state)
    assert client.post("/chaos/reset").status_code == 403


async def test_apply_chaos_inactive_returns_none():
    assert await apply_chaos(ChaosState()) is None


async def test_apply_chaos_expired_window_returns_none():
    state = ChaosState(error_rate=1.0, error_until=int(time.time()) - 10)
    assert await apply_chaos(state) is None


async def test_apply_chaos_error_rate_one_always_fails():
    state = ChaosState(error_rate=1.0, error_until=int(time.time()) + 60, error_status=503)
    assert await apply_chaos(state) == 503


async def test_apply_chaos_error_rate_zero_never_fails():
    state = ChaosState(error_rate=0.0, error_until=int(time.time()) + 60)
    assert await apply_chaos(state) is None


async def test_apply_chaos_probability(monkeypatch):
    state = ChaosState(error_rate=0.5, error_until=int(time.time()) + 60, error_status=502)
    monkeypatch.setattr("mesh_common.chaos.random.random", lambda: 0.4)
    assert await apply_chaos(state) == 502
    monkeypatch.setattr("mesh_common.chaos.random.random", lambda: 0.6)
    assert await apply_chaos(state) is None


async def test_apply_chaos_latency_sleeps(monkeypatch):
    sleeps: list[float] = []

    async def fake_sleep(seconds):
        sleeps.append(seconds)

    monkeypatch.setattr("mesh_common.chaos.asyncio.sleep", fake_sleep)
    state = ChaosState(latency_ms=2000, latency_until=int(time.time()) + 60)
    assert await apply_chaos(state) is None
    assert sleeps == [2.0]


def test_chaos_error_response_shape():
    resp = chaos_error_response(502)
    assert resp.status_code == 502
    assert resp.body == b'{"error":"chaos-injected","status":502}'
