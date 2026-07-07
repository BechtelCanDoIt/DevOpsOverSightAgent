"""Topology-layer tests: catalog dependency directions, trace-id normalization
(the CRITICAL 64/128-bit gotcha), correlation URLs, and runbook execution +
audit. All pure/in-process — no network except the stubbed disable-chaos call.
"""

from __future__ import annotations

import json

import httpx
import pytest
import respx

from devops_oversight_agent import audit, correlation, runbooks
from devops_oversight_agent.catalog import get_dependencies, list_all_services
from devops_oversight_agent import topology_tools as tt


# ── catalog ─────────────────────────────────────────────────────────────────

def test_catalog_has_seven_services():
    assert len(list_all_services()) == 7


def test_order_downstream_includes_async_notification():
    down = get_dependencies("order-service", "downstream")
    assert "notification-service" in down  # async NATS edge
    assert "payment-service" in down


def test_payment_upstream_is_order():
    assert get_dependencies("payment-service", "upstream") == ["order-service"]


def test_notification_upstream_via_async_edge():
    assert get_dependencies("notification-service", "upstream") == ["order-service"]


def test_unknown_service_no_deps():
    assert get_dependencies("nope-service", "both") == []


# ── trace-id normalization (regression for the CRITICAL gotcha) ───────────────

def test_normalize_128bit_passthrough():
    assert correlation.normalize_trace_id(correlation.DEMO_TRACE_ID) == correlation.DEMO_TRACE_ID


def test_normalize_64bit_left_pads_to_128():
    dd64 = "deadbeefdeadbeef"
    out = correlation.normalize_trace_id(dd64)
    assert len(out) == 32
    assert out == "0000000000000000deadbeefdeadbeef"


def test_normalize_uppercase_and_whitespace():
    assert correlation.normalize_trace_id("  ABC123DEF456789012345678DEADBEEF ") == correlation.DEMO_TRACE_ID


def test_to_datadog_64_is_low_16():
    dd64 = correlation.to_datadog_64(correlation.DEMO_TRACE_ID)
    assert len(dd64) == 16
    assert dd64 == correlation.DEMO_TRACE_ID[-16:]


def test_splunk_spl_uses_128bit_form():
    spl = correlation.build_splunk_spl("deadbeefdeadbeef")  # 64-bit input
    assert '0000000000000000deadbeefdeadbeef' in spl  # normalized to 128-bit for Splunk


def test_involved_services_only_for_demo_trace():
    assert correlation.infer_involved_services(correlation.DEMO_TRACE_ID) == correlation.DEMO_TRACE_SERVICES
    assert correlation.infer_involved_services("beef") == []


# ── correlate_trace tool ──────────────────────────────────────────────────────

def test_correlate_trace_tool_shape(monkeypatch):
    monkeypatch.setenv("DD_SITE", "datadoghq.com")
    result = json.loads(tt.correlate_trace.invoke({"trace_id": correlation.DEMO_TRACE_ID}))
    assert result["trace_id"] == correlation.DEMO_TRACE_ID
    assert "app.datadoghq.com/apm/trace/" in result["datadog_url"]
    assert result["involved_services"] == correlation.DEMO_TRACE_SERVICES


# ── runbooks ──────────────────────────────────────────────────────────────────

@pytest.fixture(autouse=True)
def clean_audit():
    audit.reset_for_tests()


async def test_list_runbooks_has_four():
    assert {r["id"] for r in runbooks.list_runbooks()} == {
        "restart-service", "clear-cache", "disable-chaos", "freeze-deploys"
    }


async def test_unknown_runbook_raises():
    with pytest.raises(ValueError, match="Unknown runbook"):
        await runbooks.execute_runbook("nope", {})


@respx.mock
async def test_disable_chaos_posts_reset_and_audits():
    respx.post("http://payment-service:9099/chaos/reset").mock(return_value=httpx.Response(200))
    steps = await runbooks.execute_runbook("disable-chaos", {"service": "payment-service"})
    assert any("POST http://payment-service:9099/chaos/reset" in s for s in steps)
    assert any("HTTP 200" in s for s in steps)
    assert any("disable-chaos service=payment-service" in e for e in audit.get_audit_log())


async def test_freeze_deploys_sets_flag():
    await runbooks.execute_runbook("freeze-deploys", {"reason": "incident"})
    assert audit.is_deploy_frozen() is True
    assert audit.deploy_freeze_reason() == "incident"


async def test_run_runbook_tool_returns_steps(monkeypatch):
    async def fake(runbook_id, params):
        return ["step-a", "step-b"]

    monkeypatch.setattr(tt.runbooks, "execute_runbook", fake)
    out = json.loads(await tt.run_runbook.ainvoke({"id": "restart-service", "params": {"service": "x"}}))
    assert out == {"runbook": "restart-service", "steps": ["step-a", "step-b"]}
