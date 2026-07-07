"""datadog-mock-mcp: FastMCP streamable-http mock of the Datadog MCP server (:8401).

Ported from the Ballerina source
(``MCP Best Practices Approach/code/mcp/datadog-mock-mcp/datadog_mock_mcp.bal``).
Tool names, parameter names/optionality, result JSON shapes, and mock data are
identical; the JSON-RPC protocol layer is handled by the official ``mcp`` SDK
instead of the hand-rolled Ballerina dispatcher.
"""

from __future__ import annotations

import json
import logging
import os

from mcp.server.fastmcp import FastMCP
from starlette.requests import Request
from starlette.responses import JSONResponse

from datadog_mock_mcp.mock_data import (
    MOCK_METRICS,
    MOCK_TRACE,
    filter_logs,
    filter_monitors,
    lookup_metric,
)

logger = logging.getLogger("datadog-mock-mcp")

mcp = FastMCP(
    "datadog-mock-mcp",
    host="0.0.0.0",
    port=int(os.environ.get("PORT", "8401")),
)


def _log_request() -> None:
    # Ballerina logs 'datadog-mock-mcp request' with the JSON-RPC method for
    # every request; the FastMCP SDK owns the protocol layer here, so we emit
    # the same message text per tool invocation (method is always tools/call).
    logger.info('datadog-mock-mcp request method="tools/call"')


@mcp.custom_route("/health", methods=["GET"])
async def health(request: Request) -> JSONResponse:
    return JSONResponse({"status": "UP", "service": "datadog-mock-mcp"})


@mcp.tool()
def get_datadog_metric(metric_name: str, from_time: int | None = None, to_time: int | None = None) -> str:
    """Get a metric time series."""
    _log_request()
    ms = lookup_metric(metric_name)
    if ms is not None:
        return json.dumps(ms)
    return json.dumps({"metric": metric_name, "series": [], "note": "No data in mock — try payment.request.errors"})


@mcp.tool()
def search_datadog_metrics(query: str) -> str:
    """Search metric names."""
    _log_request()
    results = [
        {"metric": v["metric"], "display_name": v["display_name"], "unit": v["unit"]}
        for k, v in MOCK_METRICS.items()
        if query.lower() in k.lower()
    ]
    if len(results) > 0:
        return json.dumps(results)
    return json.dumps([{"metric": f"mock.{query}", "display_name": f"Mock {query}"}])


@mcp.tool()
def search_datadog_error_tracking_issues(query: str = "") -> str:
    """Search error tracking issues."""
    _log_request()
    issues = [
        {"id": "ERR-001", "title": "502 Bad Gateway in payment-service", "service": "payment-service", "occurrences": 47, "status": "open"},
        {"id": "ERR-002", "title": "order creation failed: payment-service 502", "service": "order-service", "occurrences": 40, "status": "open"},
    ]
    if query != "":
        filtered = [
            issue for issue in issues
            if query.lower() in issue["title"].lower() or query in issue["service"]
        ]
        return json.dumps(filtered)
    return json.dumps(issues)


@mcp.tool()
def get_datadog_trace(trace_id: str) -> str:
    """Get a full trace by ID."""
    _log_request()
    if trace_id.startswith("abc123"):
        return json.dumps(MOCK_TRACE)
    return json.dumps({"trace_id": trace_id, "spans": [], "note": "No trace in mock — use demo trace_id starting with abc123"})


@mcp.tool()
def apm_search_spans(service: str = "", operation: str = "") -> str:
    """Search APM spans by service/operation."""
    _log_request()
    spans = [dict(s) for s in MOCK_TRACE["spans"]]
    if service != "":
        spans = [s for s in spans if service in s["service"]]
    if operation != "":
        spans = [s for s in spans if operation in s["operation"]]
    return json.dumps(spans)


@mcp.tool()
def search_datadog_logs(query: str = "") -> str:
    """Search Datadog log management."""
    _log_request()
    return json.dumps(filter_logs(query))


@mcp.tool()
def search_datadog_monitors(query: str = "") -> str:
    """Search monitors by name or tag."""
    _log_request()
    return json.dumps(filter_monitors(query))


@mcp.tool()
def get_datadog_dashboard(dashboard_id: str) -> str:
    """Get a dashboard by ID."""
    _log_request()
    return json.dumps({
        "id": dashboard_id,
        "title": "DevOps POC — Service Overview",
        "url": f"https://app.datadoghq.com/dashboard/{dashboard_id}",
        "widgets": ["Service Error Rate", "Request Duration P99", "Active Monitors"],
    })


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    mcp.run(transport="streamable-http")


if __name__ == "__main__":
    main()
