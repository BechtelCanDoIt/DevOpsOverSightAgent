"""Mock log events representing the demo incident scenario.

payment-service 502 spike with a consistent trace_id.
Ported verbatim from the Ballerina source (mock_data.bal).
"""

from __future__ import annotations

from typing import Any

DEMO_TRACE_ID = "abc123def456789012345678deadbeef"

# LogEvent shape: _time, service, trace_id, span_id, message, status, latency_ms
MOCK_EVENTS: list[dict[str, Any]] = [
    {
        "_time": "2026-06-09T10:00:01Z",
        "service": "payment-service",
        "trace_id": DEMO_TRACE_ID,
        "span_id": "1234567890abcdef",
        "message": "POST /charge HTTP/1.1 502 Bad Gateway",
        "status": 502,
        "latency_ms": 2150,
    },
    {
        "_time": "2026-06-09T10:00:02Z",
        "service": "order-service",
        "trace_id": DEMO_TRACE_ID,
        "span_id": "fedcba0987654321",
        "message": "payment charge failed — retrying",
        "status": 200,
        "latency_ms": 2200,
    },
    {
        "_time": "2026-06-09T10:00:03Z",
        "service": "payment-service",
        "trace_id": DEMO_TRACE_ID,
        "span_id": "1234567890abcdef",
        "message": "POST /charge HTTP/1.1 502 Bad Gateway",
        "status": 502,
        "latency_ms": 2100,
    },
    {
        "_time": "2026-06-09T10:00:04Z",
        "service": "order-service",
        "trace_id": DEMO_TRACE_ID,
        "span_id": "fedcba0987654321",
        "message": "order creation failed: payment-service 502",
        "status": 500,
        "latency_ms": 4400,
    },
    {
        "_time": "2026-06-09T10:01:00Z",
        "service": "inventory-service",
        "trace_id": "99887766554433221100ffeeddccbbaa",
        "span_id": "aabbccdd11223344",
        "message": "cache miss — falling back to postgres",
        "status": 200,
        "latency_ms": 450,
    },
    {
        "_time": "2026-06-09T10:02:00Z",
        "service": "notification-service",
        "trace_id": "11223344556677889900aabbccddeeff",
        "span_id": "0011223344556677",
        "message": "order confirmation sent — order_id=ORD-001",
        "status": 200,
        "latency_ms": 55,
    },
]

INDEXES: list[str] = ["main", "devops-poc", "logs", "traces", "metrics"]

# SavedSearch shape: name, search
SAVED_SEARCHES: list[dict[str, str]] = [
    {
        "name": "Error Rate by Service",
        "search": "index=devops-poc status>=400 | stats count by service | sort -count",
    },
    {
        "name": "P99 Latency by Service",
        "search": "index=devops-poc | stats p99(latency_ms) by service",
    },
    {
        "name": "payment-service 502s",
        "search": "index=devops-poc service=payment-service status=502",
    },
    {
        "name": "Trace Correlation",
        "search": "index=devops-poc trace_id=$trace_id$ | table _time,service,message,span_id",
    },
]


def filter_events(query: str, max_results: int = 100) -> list[dict[str, Any]]:
    """Filter events by query string. Simple heuristic: check for trace_id=,
    service=, and error keywords.

    Faithful port of the Ballerina ``filterEvents`` (note: despite the comment
    above, carried over from the .bal source, the actual code implements only
    the trace_id= prefix filter and the 502/error status filter). The
    ``max_results`` cap mirrors the slice done in the Ballerina tool handler.
    """
    events = [dict(e) for e in MOCK_EVENTS]

    # trace_id filter
    if "trace_id=" in query:
        idx = query.find("trace_id=")
        remainder = query[idx + 9 :].replace('"', "")
        space_idx = remainder.find(" ")
        if space_idx != -1:
            tid = remainder[:space_idx]
        else:
            tid = remainder
        prefix_len = 8 if len(tid) > 8 else len(tid)
        prefix = tid[:prefix_len]
        events = [e for e in events if e["trace_id"].startswith(prefix)]

    # error/502 filter
    if "502" in query or "error" in query.lower():
        filtered = [e for e in events if e["status"] >= 400]
        if len(filtered) > 0:
            events = filtered

    if len(events) > max_results:
        events = events[:max_results]

    return events
