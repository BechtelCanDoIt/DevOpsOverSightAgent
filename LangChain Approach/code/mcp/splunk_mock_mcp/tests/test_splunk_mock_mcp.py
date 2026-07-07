"""splunk-mock-mcp tests — mirror the Ballerina test intent.

Tools are exercised directly (``@mcp.tool()`` returns the plain function) and
the result JSON is asserted against the fixtures in mock_data.py, including the
trace_id-prefix and 502/error filter heuristics and the empty-fallback.
"""

import json

from fastapi.testclient import TestClient

from splunk_mock_mcp import server
from splunk_mock_mcp.mock_data import DEMO_TRACE_ID, INDEXES, MOCK_EVENTS, SAVED_SEARCHES, filter_events

EXPECTED_TOOL_NAMES = {
    "splunk_run_query",
    "splunk_get_indexes",
    "splunk_get_knowledge_objects",
    "splunk_describe_query",
}


# ---------- registration / transport ----------

async def test_registered_tools_exactly_four():
    tools = await server.mcp.list_tools()
    assert len(tools) == 4
    assert {t.name for t in tools} == EXPECTED_TOOL_NAMES


def test_health_route():
    app = server.mcp.streamable_http_app()
    with TestClient(app) as client:
        resp = client.get("/health")
        assert resp.status_code == 200
        assert resp.json() == {"status": "UP", "service": "splunk-mock-mcp"}


# ---------- splunk_run_query ----------

def test_run_query_unfiltered_returns_all():
    result = json.loads(server.splunk_run_query("index=devops-poc"))
    assert result["query"] == "index=devops-poc"
    assert result["result_count"] == len(MOCK_EVENTS)
    assert len(result["events"]) == len(MOCK_EVENTS)


def test_run_query_trace_id_prefix_match():
    # Full demo trace id — 8-char prefix keeps only the demo-trace events.
    result = json.loads(server.splunk_run_query(f"trace_id={DEMO_TRACE_ID}"))
    assert result["result_count"] == 4
    assert all(e["trace_id"] == DEMO_TRACE_ID for e in result["events"])


def test_run_query_502_filter():
    result = json.loads(server.splunk_run_query("service=payment-service 502"))
    # 502 keyword -> status>=400 filter; demo trace 502s survive.
    assert all(e["status"] >= 400 for e in result["events"])
    assert result["result_count"] >= 2


def test_run_query_error_keyword_empty_fallback_keeps_all():
    # An "error" keyword with no status>=400 among an already-narrowed set must
    # fall back to the pre-filter set (never return zero) — the .bal behavior.
    # Here we exercise via filter_events with only 200-status events.
    events = filter_events("trace_id=11223344 error")  # notification event, status 200
    assert len(events) == 1  # empty>=400 filter falls back, not dropped to zero


def test_run_query_max_results_cap():
    result = json.loads(server.splunk_run_query("index=devops-poc", max_results=2))
    assert result["result_count"] == 2


# ---------- other tools ----------

def test_get_indexes_bare_array():
    result = json.loads(server.splunk_get_indexes())
    assert result == INDEXES  # bare array, not wrapped


def test_get_knowledge_objects_returns_saved_searches():
    result = json.loads(server.splunk_get_knowledge_objects())
    assert result == SAVED_SEARCHES


def test_describe_query_estimated_events():
    result = json.loads(server.splunk_describe_query("index=main status=502"))
    assert result["query"] == "index=main status=502"
    assert result["estimated_events"] == 42
    assert "index=main status=502" in result["explanation"]
