"""notification-service tests — the async order-event handler.

The handler is factored out so it can be driven directly with fake NATS
messages: happy path (logs "notification sent" with the parsed trace_id/span_id
— the Splunk async-leg join), malformed traceparent, malformed JSON, and
chaos-drop. NEVER raises. Also asserts /health is the only HTTP route.

Assertions read caplog records (message + the trace_id/span_id/order_id extras
carried on each record) rather than parsing stdout — the JSON stdout shape is
covered by mesh_common's obs tests.
"""

from __future__ import annotations

import json
import logging

import pytest
from fastapi.testclient import TestClient

from mesh_common import build_traceparent

from notification_service import app as app_mod
from notification_service.app import app, handle_order_event

TID = "abc123def456789012345678deadbeef"
SID = "1234567890abcdef"


@pytest.fixture(autouse=True)
def caplog_info(caplog):
    caplog.set_level(logging.INFO, logger="devopspoc")
    return caplog


class FakeMsg:
    def __init__(self, obj_or_bytes):
        if isinstance(obj_or_bytes, (bytes, bytearray)):
            self.data = bytes(obj_or_bytes)
        else:
            self.data = json.dumps(obj_or_bytes).encode("utf-8")


def envelope(traceparent):
    return {"orderId": "ORD-1", "customerId": 1, "total": 39.98, "traceparent": traceparent}


def _rec(caplog, message_substr):
    return next((r for r in caplog.records if message_substr in r.getMessage()), None)


async def test_happy_path_logs_join(caplog_info):
    await handle_order_event(FakeMsg(envelope(build_traceparent(TID, SID))))
    rec = _rec(caplog_info, "notification sent")
    assert rec is not None
    assert rec.trace_id == TID  # parsed from the envelope, not empty — the join
    assert rec.span_id == SID
    assert rec.order_id == "ORD-1"


async def test_malformed_traceparent_skips_without_crash(caplog_info):
    await handle_order_event(FakeMsg(envelope("not-a-traceparent")))
    assert _rec(caplog_info, "bad traceparent") is not None
    assert _rec(caplog_info, "notification sent") is None


async def test_malformed_json_skips_without_crash(caplog_info):
    await handle_order_event(FakeMsg(b"{ this is not json"))
    assert _rec(caplog_info, "failed to process order event") is not None


async def test_missing_fields_skips_without_crash(caplog_info):
    # Pydantic validation failure must be caught, not raised.
    await handle_order_event(FakeMsg({"orderId": "ORD-1"}))  # missing traceparent/total
    assert _rec(caplog_info, "notification sent") is None


async def test_chaos_drops_message(caplog_info):
    app_mod.chaos.error_rate = 1.0
    app_mod.chaos.error_until = 2**31
    try:
        await handle_order_event(FakeMsg(envelope(build_traceparent(TID, SID))))
        assert _rec(caplog_info, "dropped by chaos") is not None
        assert _rec(caplog_info, "notification sent") is None
    finally:
        app_mod.chaos.error_rate = 0.0
        app_mod.chaos.error_until = 0


def test_only_health_route():
    with TestClient(app) as c:
        assert c.get("/health").json() == {"status": "UP", "service": "notification-service"}
        assert c.post("/orders", json={}).status_code == 404  # no business endpoints
