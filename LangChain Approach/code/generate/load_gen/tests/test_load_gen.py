"""Unit tests for load-gen — port of the Ballerina tests/load_gen_test.bal.

Pure logic first (env-var defaulting, pattern parsing, the RPS schedule,
weighted domain selection via the seeded entry point `pick_domain_at`, CLI
pattern selection, bounded random helpers), plus respx-mocked flow tests that
the Ballerina suite could not express (no HTTP mocking there).
"""

from __future__ import annotations

import time
from types import SimpleNamespace

import httpx
import pytest
import respx

from load_gen import main as lg
from mesh_common import env_or

# ── env_or (mesh_common obs) ──────────────────────────────────────────────────


def test_env_or_fallback_when_unset(monkeypatch):
    monkeypatch.delenv("LOADGEN_TEST_DEFINITELY_UNSET_VAR", raising=False)
    got = env_or("LOADGEN_TEST_DEFINITELY_UNSET_VAR", "fallback-value")
    assert got == "fallback-value", "missing env var should yield the fallback"


def test_env_or_returns_set_value_when_present(monkeypatch):
    monkeypatch.setenv("LOADGEN_TEST_SET_VAR", "set-value")
    assert env_or("LOADGEN_TEST_SET_VAR", "fallback-value") == "set-value"


# ── select_pattern (CLI / env arg parsing) ────────────────────────────────────


def test_select_pattern_from_cli_flag():
    assert lg.select_pattern(["--pattern", "spike"]) == "spike"


def test_select_pattern_defaults_to_baseline(monkeypatch):
    monkeypatch.delenv("LOADGEN_PATTERN", raising=False)
    assert lg.select_pattern([]) == "baseline"


def test_select_pattern_ignores_dangling_flag(monkeypatch):
    # `--pattern` with no following value should fall through to the default.
    monkeypatch.delenv("LOADGEN_PATTERN", raising=False)
    assert lg.select_pattern(["--pattern"]) == "baseline"


def test_select_pattern_honors_env_var(monkeypatch):
    monkeypatch.setenv("LOADGEN_PATTERN", "regression")
    assert lg.select_pattern([]) == "regression"


# ── load_pattern (YAML → Pattern, camelCase keys) ─────────────────────────────


def test_load_pattern_baseline_parses_cleanly():
    p = lg.load_pattern("baseline")
    assert p.name == "baseline"
    assert p.base_rps == 5
    assert p.workers == 4
    assert p.duration_seconds == 0
    assert p.spike is None, "baseline pattern has no spike window"
    # Weights match patterns/baseline.yaml.
    assert p.weights.store == 30
    assert p.weights.customer == 15
    assert p.weights.inventory == 25
    assert p.weights.invoice == 10
    assert p.weights.order == 20


def test_load_pattern_regression_parses_cleanly():
    p = lg.load_pattern("regression")
    assert p.name == "regression"
    assert p.base_rps == 8
    assert p.workers == 6
    assert p.duration_seconds == 0
    assert p.spike is None
    assert p.weights.store == 20
    assert p.weights.customer == 5
    assert p.weights.inventory == 45
    assert p.weights.invoice == 5
    assert p.weights.order == 25


def test_load_pattern_spike_has_spike_window():
    p = lg.load_pattern("spike")
    assert p.name == "spike"
    assert p.base_rps == 5
    assert p.workers == 6
    s = p.spike
    assert s is not None, "spike pattern must declare a spike window"
    assert s.after_seconds == 60
    assert s.rps == 25
    assert s.for_seconds == 60
    assert p.weights.order == 40


def test_load_pattern_unknown_name_raises():
    with pytest.raises(FileNotFoundError):
        lg.load_pattern("definitely-not-a-pattern")


# ── current_rps (RPS schedule given elapsed time) ─────────────────────────────


def _pattern(**overrides) -> lg.Pattern:
    base = {
        "name": "t",
        "baseRps": 5,
        "workers": 4,
        "durationSeconds": 0,
        "weights": {"store": 1, "customer": 1, "inventory": 1, "invoice": 1, "order": 1},
    }
    base.update(overrides)
    return lg.Pattern.model_validate(base)


def test_current_rps_baseline_is_constant():
    p = _pattern()
    assert lg.current_rps(p, 0) == 5
    assert lg.current_rps(p, 30) == 5
    assert lg.current_rps(p, 9999) == 5


def test_current_rps_honors_spike_window():
    p = _pattern(name="spike", workers=6,
                 spike={"afterSeconds": 60, "rps": 25, "forSeconds": 60})
    # Before the window.
    assert lg.current_rps(p, 0) == 5
    assert lg.current_rps(p, 59) == 5
    # Inside the window (inclusive start, exclusive end).
    assert lg.current_rps(p, 60) == 25, "spike starts at afterSeconds"
    assert lg.current_rps(p, 119) == 25
    # After the window.
    assert lg.current_rps(p, 120) == 5, "spike ends after forSeconds"
    assert lg.current_rps(p, 600) == 5


# ── pick_domain_at (deterministic weighted selection) ─────────────────────────


def test_pick_domain_at_respects_cumulative_weights():
    # Total weight = 100; cumulative boundaries: store[0,30), customer[30,45),
    # inventory[45,70), invoice[70,80), order[80,100).
    w = lg.Weights(store=30, customer=15, inventory=25, invoice=10, order=20)
    assert lg.pick_domain_at(w, 0.00) == "store"
    assert lg.pick_domain_at(w, 0.29) == "store"
    assert lg.pick_domain_at(w, 0.30) == "customer"
    assert lg.pick_domain_at(w, 0.44) == "customer"
    assert lg.pick_domain_at(w, 0.45) == "inventory"
    assert lg.pick_domain_at(w, 0.69) == "inventory"
    assert lg.pick_domain_at(w, 0.70) == "invoice"
    assert lg.pick_domain_at(w, 0.79) == "invoice"
    assert lg.pick_domain_at(w, 0.80) == "order"
    assert lg.pick_domain_at(w, 0.99) == "order"


def test_pick_domain_at_zero_weights_falls_back_to_store():
    w = lg.Weights(store=0, customer=0, inventory=0, invoice=0, order=0)
    assert lg.pick_domain_at(w, 0.0) == "store"
    assert lg.pick_domain_at(w, 0.5) == "store"
    assert lg.pick_domain_at(w, 0.99) == "store"


def test_pick_domain_at_skips_zero_weight_domains():
    # Only `order` has weight; every roll must select it.
    w = lg.Weights(store=0, customer=0, inventory=0, invoice=0, order=10)
    assert lg.pick_domain_at(w, 0.0) == "order"
    assert lg.pick_domain_at(w, 0.5) == "order"
    assert lg.pick_domain_at(w, 0.99) == "order"


# ── rand_int / rand_sku (bounded randomness — sample invariants) ──────────────


def test_rand_int_stays_within_inclusive_bounds():
    lo, hi = 1, 5
    for _ in range(200):
        n = lg.rand_int(lo, hi)
        assert lo <= n <= hi, f"rand_int({lo}, {hi}) returned {n} (out of range)"


def test_rand_sku_shape_and_range():
    for _ in range(100):
        sku = lg.rand_sku()
        assert sku.startswith("SKU-00"), f'rand_sku() must start with "SKU-00", got "{sku}"'
        assert len(sku) == 7, "rand_sku format is SKU-00X (7 chars)"


# ── Domain flows (respx-mocked HTTP) ──────────────────────────────────────────


@respx.mock
async def test_order_flow_posts_order_payload():
    route = respx.post("http://order:9090/orders").mock(
        return_value=httpx.Response(201, json={"orderId": "ord-1"})
    )
    await lg.order_flow()
    assert route.called
    import json

    body = json.loads(route.calls.last.request.content)
    assert 1 <= body["customerId"] <= 5
    assert len(body["items"]) == 1
    item = body["items"][0]
    assert item["sku"].startswith("SKU-00")
    assert 1 <= item["qty"] <= 3


@respx.mock
async def test_store_flow_hits_list_and_detail():
    list_route = respx.get("http://store:9090/products").mock(
        return_value=httpx.Response(200, json=[])
    )
    detail_route = respx.get(url__regex=r"http://store:9090/products/[1-5]$").mock(
        return_value=httpx.Response(200, json={})
    )
    await lg.store_flow()
    assert list_route.called
    assert detail_route.called


@respx.mock
async def test_customer_flow_create_branch(monkeypatch):
    # Pin the roll below 0.3 → the ~30% create branch.
    monkeypatch.setattr(
        lg, "random", SimpleNamespace(random=lambda: 0.1, randint=lambda lo, hi: 7)
    )
    route = respx.post("http://customer:9090/customers").mock(
        return_value=httpx.Response(201, json={"id": 7})
    )
    await lg.customer_flow()
    assert route.called
    import json

    body = json.loads(route.calls.last.request.content)
    assert body == {"name": "user-7", "email": "user-7@example.com"}


@respx.mock
async def test_customer_flow_read_branch(monkeypatch):
    monkeypatch.setattr(
        lg, "random", SimpleNamespace(random=lambda: 0.9, randint=lambda lo, hi: 3)
    )
    route = respx.get("http://customer:9090/customers/3").mock(
        return_value=httpx.Response(200, json={"id": 3})
    )
    await lg.customer_flow()
    assert route.called


@respx.mock
async def test_run_flow_keeps_driving_on_failure(caplog):
    # Only `order` has weight, and the order front-door is down — run_flow must
    # log "flow failed: order" and swallow the error (services may be
    # mid-startup or chaos may be injected; keep driving).
    respx.post("http://order:9090/orders").mock(side_effect=httpx.ConnectError("boom"))
    p = _pattern(weights={"store": 0, "customer": 0, "inventory": 0, "invoice": 0, "order": 10})
    with caplog.at_level("ERROR"):
        await lg.run_flow(p)  # must not raise
    assert any(r.getMessage() == "flow failed: order" for r in caplog.records)


# ── worker_loop duration gate ─────────────────────────────────────────────────


@respx.mock
async def test_worker_loop_returns_when_duration_elapsed():
    # elapsed (10s) >= durationSeconds (5) → return immediately, zero requests.
    p = _pattern(durationSeconds=5)
    await lg.worker_loop(p, start_sec=int(time.time()) - 10, worker_id=0)
    assert len(respx.calls) == 0
