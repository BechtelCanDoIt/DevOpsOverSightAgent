"""W3C traceparent helpers — port of the notification-service envelope logic.

Pure functions (no NATS dependency) so the async trace-join can be unit tested
in isolation. The order-service injects ``build_traceparent`` into the NATS
``orders.created`` envelope; the notification-service parses it back with
``parse_traceparent`` and logs with the extracted trace_id/span_id — that log
line is what joins the async leg to the same trace in Splunk.
"""

from __future__ import annotations

import re

_TRACE_ID = re.compile(r"^[0-9a-f]{32}$")
_SPAN_ID = re.compile(r"^[0-9a-f]{16}$")


def build_traceparent(trace_id: str, span_id: str) -> str:
    """00-{32-hex trace id}-{16-hex span id}-01 (sampled)."""
    return f"00-{trace_id}-{span_id}-01"


def parse_traceparent(traceparent: str) -> tuple[str, str]:
    """Validate + split a W3C traceparent; returns ("", "") on any malformation.

    Same acceptance rules as the Ballerina parser: exactly 4 dash-separated
    parts, version "00", lowercase 32-hex trace id, lowercase 16-hex span id.
    """
    parts = traceparent.split("-")
    if len(parts) != 4:
        return "", ""
    version, trace_id, span_id, _flags = parts
    if version != "00":
        return "", ""
    if not _TRACE_ID.fullmatch(trace_id) or not _SPAN_ID.fullmatch(span_id):
        return "", ""
    return trace_id, span_id
