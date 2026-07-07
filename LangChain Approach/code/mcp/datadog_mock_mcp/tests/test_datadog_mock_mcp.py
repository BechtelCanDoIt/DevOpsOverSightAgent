"""Tests for datadog-mock-mcp — mirror the Ballerina test intent.

Every tool is exercised directly (the ``@mcp.tool()`` decorator returns the
plain function) and the result JSON is asserted exactly against the values in
``mock_data.bal`` / ``datadog_mock_mcp.bal``.
"""

import json

from fastapi.testclient import TestClient

from datadog_mock_mcp import server
from datadog_mock_mcp.mock_data import (
    DD_DEMO_TRACE_ID,
    MOCK_LOGS,
    MOCK_METRICS,
    MOCK_MONITORS,
    MOCK_TRACE,
    lookup_metric,
)

EXPECTED_TOOL_NAMES = {
    "get_datadog_metric",
    "search_datadog_metrics",
    "search_datadog_error_tracking_issues",
    "get_datadog_trace",
    "apm_search_spans",
    "search_datadog_logs",
    "search_datadog_monitors",
    "get_datadog_dashboard",
}


# ---------- registration / transport ----------

async def test_registered_tools_exactly_eight():
    tools = await server.mcp.list_tools()
    assert len(tools) == 8
    assert {t.name for t in tools} == EXPECTED_TOOL_NAMES


def test_health_route():
    app = server.mcp.streamable_http_app()
    with TestClient(app) as client:
        resp = client.get("/health")
        assert resp.status_code == 200
        assert resp.json() == {"status": "UP", "service": "datadog-mock-mcp"}


# ---------- get_datadog_metric ----------

def test_get_metric_exact_error_spike():
    result = json.loads(server.get_datadog_metric("payment.request.errors"))
    assert result == MOCK_METRICS["payment.request.errors"]
    assert [p["value"] for p in result["series"]] == [2.0, 18.0, 47.0, 53.0, 12.0]
    assert result["series"][0]["timestamp"] == 1749470400


def test_get_metric_exact_duration_jump():
    result = json.loads(server.get_datadog_metric("payment.request.duration"))
    assert result["unit"] == "millisecond"
    assert [p["value"] for p in result["series"]] == [120.0, 1850.0, 2150.0, 2200.0, 250.0]


def test_get_metric_fuzzy_prefix_fallback():
    # "payment.errors" is not a key; prefix "payment" matches the first
    # payment.* series in map order.
    result = json.loads(server.get_datadog_metric("payment.errors"))
    assert result == MOCK_METRICS["payment.request.errors"]


def test_get_metric_fuzzy_no_dot():
    # No dot: the whole name is the prefix.
    result = json.loads(server.get_datadog_metric("order"))
    assert result == MOCK_METRICS["order.request.errors"]


def test_get_metric_unknown_returns_note():
    result = json.loads(server.get_datadog_metric("cpu.usage"))
    assert result == {
        "metric": "cpu.usage",
        "series": [],
        "note": "No data in mock — try payment.request.errors",
    }


def test_lookup_metric_none_for_unknown_prefix():
    assert lookup_metric("cpu.usage") is None


def test_get_metric_ignores_time_range_args():
    result = json.loads(server.get_datadog_metric("payment.request.errors", from_time=1, to_time=2))
    assert result == MOCK_METRICS["payment.request.errors"]


# ---------- search_datadog_metrics ----------

def test_search_metrics_match():
    result = json.loads(server.search_datadog_metrics("payment"))
    assert result == [
        {"metric": "payment.request.errors", "display_name": "Payment Request Errors", "unit": "count"},
        {"metric": "payment.request.duration", "display_name": "Payment Duration (ms)", "unit": "millisecond"},
    ]


def test_search_metrics_fallback_mock_entry():
    result = json.loads(server.search_datadog_metrics("foo"))
    assert result == [{"metric": "mock.foo", "display_name": "Mock foo"}]


# ---------- search_datadog_error_tracking_issues ----------

def test_error_tracking_issues_default():
    result = json.loads(server.search_datadog_error_tracking_issues())
    assert result == [
        {"id": "ERR-001", "title": "502 Bad Gateway in payment-service", "service": "payment-service", "occurrences": 47, "status": "open"},
        {"id": "ERR-002", "title": "order creation failed: payment-service 502", "service": "order-service", "occurrences": 40, "status": "open"},
    ]


def test_error_tracking_issues_title_filter():
    result = json.loads(server.search_datadog_error_tracking_issues(query="Gateway"))
    assert [i["id"] for i in result] == ["ERR-001"]


def test_error_tracking_issues_service_filter_case_sensitive():
    # service match is case-sensitive in the Ballerina source (svc.includes(query))
    result = json.loads(server.search_datadog_error_tracking_issues(query="order-service"))
    assert [i["id"] for i in result] == ["ERR-002"]


# ---------- get_datadog_trace ----------

def test_get_trace_demo_id():
    result = json.loads(server.get_datadog_trace(DD_DEMO_TRACE_ID))
    assert result == MOCK_TRACE
    assert len(result["spans"]) == 4
    payment_span = result["spans"][3]
    assert payment_span["service"] == "payment-service"
    assert payment_span["status"] == "error"
    assert payment_span["error"] == "502 Bad Gateway"
    assert result["trace_id"] == "abc123def456789012345678deadbeef"


def test_get_trace_abc123_prefix_matches():
    # The Ballerina source matches on startsWith("abc123").
    result = json.loads(server.get_datadog_trace("abc123"))
    assert result == MOCK_TRACE


def test_get_trace_unknown_id_returns_note():
    result = json.loads(server.get_datadog_trace("deadbeef00000000"))
    assert result == {
        "trace_id": "deadbeef00000000",
        "spans": [],
        "note": "No trace in mock — use demo trace_id starting with abc123",
    }


# ---------- apm_search_spans ----------

def test_apm_search_spans_no_filters():
    result = json.loads(server.apm_search_spans())
    assert result == MOCK_TRACE["spans"]
    assert len(result) == 4


def test_apm_search_spans_service_filter():
    result = json.loads(server.apm_search_spans(service="payment"))
    assert result == [
        {"service": "payment-service", "operation": "POST /charge", "duration_ms": 2150, "status": "error", "error": "502 Bad Gateway"},
    ]


def test_apm_search_spans_operation_filter():
    result = json.loads(server.apm_search_spans(operation="POST"))
    assert [s["operation"] for s in result] == ["POST /orders", "POST /reserve", "POST /charge"]


def test_apm_search_spans_combined_filters():
    result = json.loads(server.apm_search_spans(service="order", operation="POST"))
    assert [s["service"] for s in result] == ["order-service"]


# ---------- search_datadog_logs ----------

def test_search_logs_default_all():
    result = json.loads(server.search_datadog_logs())
    assert result == MOCK_LOGS
    assert all(log["trace_id"] == DD_DEMO_TRACE_ID for log in result)


def test_search_logs_message_filter():
    result = json.loads(server.search_datadog_logs(query="502"))
    assert len(result) == 2
    assert all(log["message"] == "POST /charge 502 Bad Gateway" for log in result)

    result = json.loads(server.search_datadog_logs(query="retrying"))
    assert [log["service"] for log in result] == ["order-service"]


def test_search_logs_service_filter_case_sensitive():
    # message match is lowercased, service match is not (per the .bal source)
    assert json.loads(server.search_datadog_logs(query="ORDER-SERVICE")) == []
    result = json.loads(server.search_datadog_logs(query="order-service"))
    assert [log["status"] for log in result] == ["warn"]


# ---------- search_datadog_monitors ----------

def test_search_monitors_default_all():
    result = json.loads(server.search_datadog_monitors())
    assert result == MOCK_MONITORS
    assert result[0] == {
        "id": "MON-001",
        "name": "payment-service error rate > 10%",
        "status": "Alert",
        "type": "metric alert",
        "tags": ["service:payment-service", "env:demo"],
    }


def test_search_monitors_name_filter():
    result = json.loads(server.search_datadog_monitors(query="latency"))
    assert [m["id"] for m in result] == ["MON-002"]


def test_search_monitors_tag_filter():
    result = json.loads(server.search_datadog_monitors(query="env:demo"))
    assert [m["id"] for m in result] == ["MON-001"]


def test_search_monitors_tag_filter_query_lowercased():
    # Query is lowercased before tag comparison; the tag itself is not.
    result = json.loads(server.search_datadog_monitors(query="SERVICE:ORDER"))
    assert [m["id"] for m in result] == ["MON-002"]


# ---------- get_datadog_dashboard ----------

def test_get_dashboard():
    result = json.loads(server.get_datadog_dashboard("dash-123"))
    assert result == {
        "id": "dash-123",
        "title": "DevOps POC — Service Overview",
        "url": "https://app.datadoghq.com/dashboard/dash-123",
        "widgets": ["Service Error Rate", "Request Duration P99", "Active Monitors"],
    }
