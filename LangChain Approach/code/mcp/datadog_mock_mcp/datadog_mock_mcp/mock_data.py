"""Demo scenario: payment-service 502 spike — metric time series, trace, monitors.

Ported verbatim from the Ballerina source
(``MCP Best Practices Approach/code/mcp/datadog-mock-mcp/mock_data.bal``).
"""

from __future__ import annotations

DD_DEMO_TRACE_ID = "abc123def456789012345678deadbeef"

MOCK_METRICS: dict[str, dict] = {
    "payment.request.errors": {
        "metric": "payment.request.errors",
        "display_name": "Payment Request Errors",
        "unit": "count",
        "series": [
            {"timestamp": 1749470400, "value": 2.0},
            {"timestamp": 1749470460, "value": 18.0},
            {"timestamp": 1749470520, "value": 47.0},
            {"timestamp": 1749470580, "value": 53.0},
            {"timestamp": 1749470640, "value": 12.0},
        ],
    },
    "payment.request.duration": {
        "metric": "payment.request.duration",
        "display_name": "Payment Duration (ms)",
        "unit": "millisecond",
        "series": [
            {"timestamp": 1749470400, "value": 120.0},
            {"timestamp": 1749470460, "value": 1850.0},
            {"timestamp": 1749470520, "value": 2150.0},
            {"timestamp": 1749470580, "value": 2200.0},
            {"timestamp": 1749470640, "value": 250.0},
        ],
    },
    "order.request.errors": {
        "metric": "order.request.errors",
        "display_name": "Order Request Errors",
        "unit": "count",
        "series": [
            {"timestamp": 1749470400, "value": 0.0},
            {"timestamp": 1749470460, "value": 15.0},
            {"timestamp": 1749470520, "value": 40.0},
            {"timestamp": 1749470580, "value": 45.0},
        ],
    },
}

MOCK_TRACE: dict = {
    "trace_id": DD_DEMO_TRACE_ID,
    "spans": [
        {"service": "order-service", "operation": "POST /orders", "duration_ms": 4400, "status": "error", "error": None},
        {"service": "customer-service", "operation": "GET /customers/{id}", "duration_ms": 45, "status": "ok", "error": None},
        {"service": "inventory-service", "operation": "POST /reserve", "duration_ms": 55, "status": "ok", "error": None},
        {"service": "payment-service", "operation": "POST /charge", "duration_ms": 2150, "status": "error", "error": "502 Bad Gateway"},
    ],
    "services": ["order-service", "customer-service", "inventory-service", "payment-service"],
}

MOCK_MONITORS: list[dict] = [
    {"id": "MON-001", "name": "payment-service error rate > 10%", "status": "Alert", "type": "metric alert",
     "tags": ["service:payment-service", "env:demo"]},
    {"id": "MON-002", "name": "order-service p99 latency > 2s", "status": "OK", "type": "metric alert",
     "tags": ["service:order-service"]},
    {"id": "MON-003", "name": "inventory cache miss rate spike", "status": "OK", "type": "metric alert",
     "tags": ["service:inventory-service"]},
]

MOCK_LOGS: list[dict] = [
    {"timestamp": "2026-06-09T10:00:01Z", "service": "payment-service", "message": "POST /charge 502 Bad Gateway", "status": "error", "trace_id": DD_DEMO_TRACE_ID},
    {"timestamp": "2026-06-09T10:00:02Z", "service": "order-service", "message": "payment charge failed — retrying", "status": "warn", "trace_id": DD_DEMO_TRACE_ID},
    {"timestamp": "2026-06-09T10:00:03Z", "service": "payment-service", "message": "POST /charge 502 Bad Gateway", "status": "error", "trace_id": DD_DEMO_TRACE_ID},
]


def lookup_metric(name: str) -> dict | None:
    m = MOCK_METRICS.get(name)
    if m is not None:
        return m
    # Fuzzy: first word match
    dot_idx = name.find(".")
    prefix = name[:dot_idx] if dot_idx != -1 else name
    for k, v in MOCK_METRICS.items():
        if k.startswith(prefix):
            return v
    return None


def filter_monitors(query: str) -> list[dict]:
    if query == "":
        return [dict(m) for m in MOCK_MONITORS]
    results: list[dict] = []
    for m in MOCK_MONITORS:
        if query.lower() in m["name"].lower():
            results.append(m)
        else:
            tag_matched = False
            for t in m["tags"]:
                if query.lower() in t:
                    tag_matched = True
                    break
            if tag_matched:
                results.append(m)
    return results


def filter_logs(query: str) -> list[dict]:
    if query == "":
        return [dict(log) for log in MOCK_LOGS]
    results: list[dict] = []
    for log in MOCK_LOGS:
        if query.lower() in log["message"].lower() or query in log["service"]:
            results.append(log)
    return results
