"""Structured logging + env helpers — port of the Ballerina obs.bal kit.

The JSON log line shape is the Splunk contract: `time`, `level`, `module`,
`message`, `trace_id`, `span_id` plus per-event domain fields. Field names and
message texts are load-bearing — the Splunk mock's filter heuristic and real
SPL saved searches key on them.
"""

from __future__ import annotations

import datetime
import json
import logging
import os
import sys

from opentelemetry import trace

_logger = logging.getLogger("devopspoc")

# LogRecord attributes that are not user-supplied `extra` fields.
_RESERVED = {
    "args", "asctime", "created", "exc_info", "exc_text", "filename", "funcName",
    "levelname", "levelno", "lineno", "message", "module", "msecs", "msg", "name",
    "pathname", "process", "processName", "relativeCreated", "stack_info",
    "taskName", "thread", "threadName",
}


def env_or(name: str, fallback: str) -> str:
    """Read an env var, falling back to a default when unset or empty."""
    v = os.environ.get(name, "")
    return v if v != "" else fallback


def span_ctx() -> tuple[str, str]:
    """Active OTel trace/span IDs as (32-hex, 16-hex); empty strings outside a span."""
    ctx = trace.get_current_span().get_span_context()
    if not ctx.is_valid:
        return "", ""
    return format(ctx.trace_id, "032x"), format(ctx.span_id, "016x")


class JsonLogFormatter(logging.Formatter):
    """Emits Ballerina-shaped JSON log lines (format="json" parity)."""

    def __init__(self, module_name: str):
        super().__init__()
        self.module_name = module_name

    def format(self, record: logging.LogRecord) -> str:
        ts = datetime.datetime.fromtimestamp(record.created, tz=datetime.timezone.utc)
        entry: dict = {
            "time": ts.isoformat(timespec="milliseconds").replace("+00:00", "Z"),
            "level": record.levelname,
            "module": self.module_name,
            "message": record.getMessage(),
        }
        for key, value in record.__dict__.items():
            if key not in _RESERVED and not key.startswith("_"):
                entry[key] = value
        return json.dumps(entry, default=str)


def setup_logging(module_name: str, level: int = logging.INFO) -> logging.Logger:
    """Route all logging through a stdout JSON handler shaped like Ballerina's.

    ``module_name`` mirrors the Ballerina package path, e.g. "devopspoc/order".
    """
    root = logging.getLogger()
    root.setLevel(level)
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonLogFormatter(module_name))
    root.handlers = [h for h in root.handlers if not isinstance(h.formatter, JsonLogFormatter)]
    root.addHandler(handler)
    # Uvicorn's own access/error loggers stay, but propagate through the JSON handler.
    for noisy in ("uvicorn", "uvicorn.access", "uvicorn.error"):
        logging.getLogger(noisy).setLevel(logging.WARNING)
    return _logger


def log_info(msg: str, **fields) -> None:
    """Structured info log with trace_id/span_id auto-injected (Splunk↔Datadog join)."""
    tid, sid = span_ctx()
    _logger.info(msg, extra={"trace_id": tid, "span_id": sid, **fields})


def log_error(msg: str, error: BaseException | str | None = None, **fields) -> None:
    tid, sid = span_ctx()
    extra: dict = {"trace_id": tid, "span_id": sid, **fields}
    if error is not None:
        extra["error"] = str(error)
    _logger.error(msg, extra=extra)
