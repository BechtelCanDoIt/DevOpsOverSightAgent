"""The 11 in-process topology tools — the Ballerina MCP Proxy's local dispatch,
now plain LangChain @tool functions on the orchestrator.

Keeping catalog/correlation/runbooks in-process (rather than behind another A2A
hop or an MCP server) puts run_runbook in the same trust domain as the human
approval gate: correlation stays in one reasoning context, and the remediation
guardrail (agent.py's HumanInTheLoopMiddleware on topology__run_runbook) cannot
be bypassed by a network boundary. Tool names keep the ``topology__`` prefix
for parity with the reference and to read clearly in the trace.
"""

from __future__ import annotations

import json

from langchain_core.tools import tool

from oversight_common.config import env_or

from . import audit, correlation, runbooks
from .catalog import catalog_lookup, get_dependencies, list_all_services


def _svc_dict(name: str) -> dict | None:
    svc = catalog_lookup(name)
    if svc is None:
        return None
    return {
        "name": svc.name, "owner": svc.owner, "slackChannel": svc.slack_channel,
        "repoUrl": svc.repo_url, "healthEndpoint": svc.health_endpoint,
        "dependencies": list(svc.dependencies), "runbookIds": list(svc.runbook_ids),
        "sla": svc.sla,
    }


@tool("topology__lookup_service")
def lookup_service(name: str) -> str:
    """Look up a service's catalog entry: owner, Slack channel, repo, health
    endpoint, dependencies, applicable runbooks, and SLA."""
    info = _svc_dict(name)
    return json.dumps(info) if info else json.dumps({"error": f"unknown service: {name}"})


@tool("topology__list_services")
def list_services() -> str:
    """List all services in the mesh catalog."""
    return json.dumps({"services": list_all_services()})


@tool("topology__get_dependencies")
def get_dependencies_tool(name: str, direction: str = "downstream") -> str:
    """Get a service's dependencies. direction: 'downstream' (what it calls),
    'upstream' (what calls it — blast radius), or 'both'."""
    return json.dumps({"service": name, "direction": direction,
                       "dependencies": get_dependencies(name, direction)})


@tool("topology__get_service_health")
def get_service_health(name: str) -> str:
    """Return the health endpoint URL for a service (the agent/operator can probe it)."""
    info = catalog_lookup(name)
    if info is None:
        return json.dumps({"error": f"unknown service: {name}"})
    return json.dumps({"service": name, "healthEndpoint": info.health_endpoint})


@tool("topology__correlate_trace")
def correlate_trace(trace_id: str) -> str:
    """Correlate a trace across systems: returns the Datadog APM URL, the Splunk
    SPL + search URL, and the services involved. Normalizes the trace id between
    Datadog's 64-bit and the 128-bit form Splunk stores."""
    dd_site = env_or("DD_SITE", "datadoghq.com")
    splunk_url = env_or("SPLUNK_URL", "https://your-splunk.splunkcloud.com")
    return json.dumps({
        "trace_id": correlation.normalize_trace_id(trace_id),
        "datadog_url": correlation.build_datadog_trace_url(trace_id, dd_site),
        "splunk_spl": correlation.build_splunk_spl(trace_id),
        "splunk_search_url": correlation.build_splunk_search_url(trace_id, splunk_url),
        "involved_services": correlation.infer_involved_services(trace_id),
    })


@tool("topology__find_recent_deploys")
def find_recent_deploys(service: str, lookback_minutes: int = 60) -> str:
    """Find recent deployments for a service (to rule a deploy in or out as a cause)."""
    deploys = correlation.find_recent_deploys(service, lookback_minutes)
    return json.dumps({"service": service, "deploys": [d.__dict__ for d in deploys]})


@tool("topology__find_related_incidents")
def find_related_incidents(service: str, lookback_days: int = 30) -> str:
    """Find past incidents for a service (history for root-cause context)."""
    incidents = correlation.find_related_incidents(service, lookback_days)
    return json.dumps({"service": service, "incidents": [i.__dict__ for i in incidents]})


@tool("topology__list_runbooks")
def list_runbooks() -> str:
    """List available remediation runbooks. Propose one and WAIT for approval —
    never run a runbook without explicit human sign-off."""
    return json.dumps({"runbooks": runbooks.list_runbooks()})


@tool("topology__run_runbook")
async def run_runbook(id: str, params: dict | None = None) -> str:
    """Execute a remediation runbook (e.g. disable-chaos). REQUIRES human
    approval — this tool is interrupt-gated; it only runs after an operator
    approves the proposal."""
    steps = await runbooks.execute_runbook(id, params or {})
    return json.dumps({"runbook": id, "steps": steps})


@tool("topology__get_audit_log")
def get_audit_log() -> str:
    """Return the runbook execution audit log for this session."""
    return json.dumps({"audit": audit.get_audit_log()})


@tool("topology__get_deploy_freeze_status")
def get_deploy_freeze_status() -> str:
    """Return whether deploys are currently frozen and why."""
    return json.dumps({"frozen": audit.is_deploy_frozen(), "reason": audit.deploy_freeze_reason()})


TOPOLOGY_TOOLS = [
    lookup_service,
    list_services,
    get_dependencies_tool,
    get_service_health,
    correlate_trace,
    find_recent_deploys,
    find_related_incidents,
    list_runbooks,
    run_runbook,
    get_audit_log,
    get_deploy_freeze_status,
]

RUN_RUNBOOK_TOOL_NAME = "topology__run_runbook"
