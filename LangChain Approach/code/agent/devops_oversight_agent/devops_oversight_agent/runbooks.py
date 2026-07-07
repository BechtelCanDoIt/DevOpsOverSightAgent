"""Remediation runbooks — ported from the Ballerina proxy runbooks.bal.

The four runbooks and their execution live in-process on the orchestrator, in
the same trust domain as the human-approval gate (the run_runbook tool is
interrupt-gated in agent.py). Each runbook holds a per-id asyncio.Lock for
idempotency. disable-chaos actually POSTs /chaos/reset on the target service —
the one runbook with a real side effect in the POC.
"""

from __future__ import annotations

import asyncio
import datetime

import httpx

from oversight_common.config import chaos_token, env_or

from . import audit

RUNBOOKS = [
    {"id": "restart-service", "name": "Restart Service",
     "description": "Gracefully restarts a service. In K8s: kubectl rollout restart.",
     "params_schema": {"type": "object", "properties": {"service": {"type": "string"}}, "required": ["service"]}},
    {"id": "clear-cache", "name": "Clear Inventory Cache",
     "description": "Flushes the Redis cache for inventory-service.",
     "params_schema": {"type": "object", "properties": {}}},
    {"id": "disable-chaos", "name": "Disable Chaos",
     "description": "Calls POST /chaos/reset on the target service to clear injected faults.",
     "params_schema": {"type": "object", "properties": {"service": {"type": "string"}}, "required": ["service"]}},
    {"id": "freeze-deploys", "name": "Freeze Deploys",
     "description": "Sets a deploy-freeze flag to prevent new deployments during an incident.",
     "params_schema": {"type": "object", "properties": {"reason": {"type": "string"}}, "required": ["reason"]}},
]

_RUNBOOK_IDS = {r["id"] for r in RUNBOOKS}
_locks: dict[str, asyncio.Lock] = {r["id"]: asyncio.Lock() for r in RUNBOOKS}


def list_runbooks() -> list[dict]:
    return RUNBOOKS


def _now() -> str:
    return datetime.datetime.now(tz=datetime.timezone.utc).isoformat()


async def execute_runbook(runbook_id: str, params: dict) -> list[str]:
    """Execute a runbook, returning the step log. Raises ValueError on an
    unknown id (parity with the Ballerina error return)."""
    if runbook_id not in _RUNBOOK_IDS:
        raise ValueError(f"Unknown runbook id: {runbook_id}")
    params = params or {}
    async with _locks[runbook_id]:
        ts = _now()
        steps: list[str] = []
        if runbook_id == "disable-chaos":
            svc = params.get("service", "unknown-service")
            # In this compose the service name IS the reachable host on :9099
            # (the Ballerina stack used unsuffixed hostnames, hence its strip).
            url = f"http://{svc}:9099"
            steps.append(f"[{ts}] POST {url}/chaos/reset")
            try:
                async with httpx.AsyncClient(timeout=5) as client:
                    resp = await client.post(f"{url}/chaos/reset", headers={"X-Chaos-Token": chaos_token()})
                steps.append(f"[{ts}] HTTP {resp.status_code}")
            except Exception as e:  # noqa: BLE001 — report, don't crash the investigation
                steps.append(f"[{ts}] call failed: {e}")
            steps.append(f"[{ts}] disable-chaos complete for {svc}")
            audit.append_audit(f"{ts} RUNBOOK disable-chaos service={svc}")
        elif runbook_id == "clear-cache":
            steps.append(f"[{ts}] flush Redis at {env_or('REDIS_HOST', 'redis')}:6379 (stub)")
            steps.append(f"[{ts}] clear-cache complete")
            audit.append_audit(f"{ts} RUNBOOK clear-cache")
        elif runbook_id == "restart-service":
            svc = params.get("service", "unknown-service")
            steps.append(f"[{ts}] kubectl rollout restart deployment/{svc} (stub)")
            steps.append(f"[{ts}] restart-service complete")
            audit.append_audit(f"{ts} RUNBOOK restart-service service={svc}")
        elif runbook_id == "freeze-deploys":
            reason = params.get("reason", "incident in progress")
            audit.set_deploy_freeze(True, reason)
            steps.append(f"[{ts}] Deploy freeze activated: {reason}")
            audit.append_audit(f"{ts} RUNBOOK freeze-deploys reason={reason}")
        return steps
