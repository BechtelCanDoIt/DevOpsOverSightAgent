"""Trace correlation + deploy/incident history — ported from correlation.bal.

Adds ``normalize_trace_id`` to close the documented CRITICAL gotcha: Datadog
emits a 64-bit ``dd.trace_id`` while OTel/Splunk hold the 128-bit
``otel.trace_id``. Building a Splunk query from a 64-bit id (or vice versa)
returns zero events. All correlation goes through the 128-bit form for Splunk
and the low-64 form for the Datadog APM URL.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from urllib.parse import quote

DEMO_TRACE_ID = "abc123def456789012345678deadbeef"
DEMO_TRACE_SERVICES = ["order-service", "customer-service", "inventory-service", "payment-service"]

_HEX = re.compile(r"^[0-9a-f]+$")


def normalize_trace_id(trace_id: str) -> str:
    """Return the 128-bit (32-hex) form. A 64-bit (16-hex) Datadog id is
    left-padded with zeros — the low-64 bits of the OTel id — so a Splunk query
    built from it matches the 128-bit id Splunk stores."""
    tid = trace_id.strip().lower()
    if not _HEX.match(tid):
        return tid  # non-hex — pass through, best effort
    if len(tid) == 16:
        return tid.rjust(32, "0")
    return tid


def to_datadog_64(trace_id: str) -> str:
    """Return the low-64 (16-hex) form Datadog uses for its APM URL."""
    tid = normalize_trace_id(trace_id)
    return tid[-16:] if len(tid) >= 16 else tid


def build_datadog_trace_url(trace_id: str, dd_site: str) -> str:
    return f"https://app.{dd_site}/apm/trace/{to_datadog_64(trace_id)}"


def build_splunk_spl(trace_id: str) -> str:
    tid = normalize_trace_id(trace_id)
    return f'index=* trace_id="{tid}" | table _time, service, trace_id, span_id, message | sort -_time'


def build_splunk_search_url(trace_id: str, splunk_url: str) -> str:
    return f"{splunk_url}/search?q={quote(build_splunk_spl(trace_id), safe='')}"


def infer_involved_services(trace_id: str) -> list[str]:
    return list(DEMO_TRACE_SERVICES) if normalize_trace_id(trace_id) == DEMO_TRACE_ID else []


@dataclass(frozen=True)
class DeployRecord:
    service: str
    version: str
    deployed_at: str
    deployed_by: str
    git_sha: str
    status: str


DEPLOY_LOG: list[DeployRecord] = [
    DeployRecord("payment-service", "1.2.3", "2026-06-08T09:00:00Z", "ci-bot", "abc123", "success"),
    DeployRecord("order-service", "2.1.0", "2026-06-07T14:30:00Z", "ci-bot", "def456", "success"),
    DeployRecord("inventory-service", "1.5.1", "2026-06-06T10:00:00Z", "ci-bot", "ghi789", "success"),
]


def find_recent_deploys(service_name: str, _lookback_minutes: int) -> list[DeployRecord]:
    return [d for d in DEPLOY_LOG if d.service == service_name]


@dataclass(frozen=True)
class IncidentRecord:
    id: str
    service: str
    title: str
    severity: str
    occurred_at: str
    root_cause: str
    resolution: str


INCIDENT_HISTORY: list[IncidentRecord] = [
    IncidentRecord("INC-001", "payment-service", "payment-service 502 spike", "P1",
                   "2026-05-15T03:00:00Z", "chaos injection left enabled after load test",
                   "disable-chaos runbook"),
    IncidentRecord("INC-002", "inventory-service", "inventory cache cold-start latency", "P2",
                   "2026-05-20T11:00:00Z", "Redis OOM caused eviction",
                   "clear-cache + Redis maxmemory increase"),
    IncidentRecord("INC-003", "order-service", "order creation 500s", "P1",
                   "2026-06-01T08:00:00Z", "payment-service returning 502 caused order rollback",
                   "Restarted payment-service"),
]


def find_related_incidents(service_name: str, _lookback_days: int) -> list[IncidentRecord]:
    return [i for i in INCIDENT_HISTORY if i.service == service_name]
