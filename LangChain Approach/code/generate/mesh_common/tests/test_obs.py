"""JSON log shape tests — the Splunk contract lives or dies on these fields."""

import json
import logging

from mesh_common.obs import JsonLogFormatter, env_or, log_error, log_info, setup_logging, span_ctx


def make_record(msg: str, **extra) -> logging.LogRecord:
    record = logging.LogRecord("devopspoc", logging.INFO, __file__, 1, msg, None, None)
    for key, value in extra.items():
        setattr(record, key, value)
    return record


def test_formatter_core_fields():
    line = JsonLogFormatter("devopspoc/order").format(make_record("order confirmed"))
    entry = json.loads(line)
    assert entry["level"] == "INFO"
    assert entry["module"] == "devopspoc/order"
    assert entry["message"] == "order confirmed"
    assert entry["time"].endswith("Z")


def test_formatter_includes_domain_fields():
    record = make_record("payment failed", trace_id="abc", span_id="def", order_id="ORD-1", status=502)
    entry = json.loads(JsonLogFormatter("devopspoc/order").format(record))
    assert entry["trace_id"] == "abc"
    assert entry["span_id"] == "def"
    assert entry["order_id"] == "ORD-1"
    assert entry["status"] == 502


def test_env_or(monkeypatch):
    monkeypatch.setenv("MESH_TEST_VAR", "set")
    assert env_or("MESH_TEST_VAR", "fallback") == "set"
    monkeypatch.setenv("MESH_TEST_VAR", "")
    assert env_or("MESH_TEST_VAR", "fallback") == "fallback"
    monkeypatch.delenv("MESH_TEST_VAR")
    assert env_or("MESH_TEST_VAR", "fallback") == "fallback"


def test_span_ctx_outside_span():
    assert span_ctx() == ("", "")


def test_log_info_injects_trace_fields(capsys):
    setup_logging("devopspoc/test")
    log_info("notification sent", order_id="ORD-9")
    entry = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert entry["message"] == "notification sent"
    assert entry["order_id"] == "ORD-9"
    assert "trace_id" in entry and "span_id" in entry


def test_log_error_includes_error_field(capsys):
    setup_logging("devopspoc/test")
    log_error("payment failed", error=ValueError("boom"), status=502)
    entry = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert entry["level"] == "ERROR"
    assert entry["error"] == "boom"
    assert entry["status"] == 502
