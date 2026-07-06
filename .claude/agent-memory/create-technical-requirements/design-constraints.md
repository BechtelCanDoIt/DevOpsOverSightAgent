---
name: design-constraints
description: Non-obvious invariants and design decisions a re-implementer of the DevOps POC must preserve
metadata:
  type: project
---

# Load-bearing design constraints (for any re-implementation)

- **Single MCP entry point:** agent talks ONLY to mcp-proxy (:8290) via BALLERINA_TOPOLOGY_MCP_URL. Proxy federates Splunk/DD backends itself. Swapping mock↔live is a SPLUNK_MCP_URL/DATADOG_MCP_URL change on the PROXY, never the agent.
- **Lazy tool loading:** tools/list returns only discover_tools + 11 topology__* tools. splunk__*/datadog__* schemas hidden in server-side registry, revealed via discover_tools(query) with top-k keyword scoring (pgvector is future). Scales to 50+ tools/vendor.
- **Propose-before-act (hard guardrail):** agent MUST call topology__list_runbooks and get human approval BEFORE topology__run_runbook. HITL gate.
- **Namespacing:** federated tool names prefixed splunk__ / datadog__ / topology__; dispatcher routes by stripping prefix.
- **Trace-ID width mismatch (most important correctness detail):** Datadog shows 64-bit dd.trace_id AND 128-bit otel.trace_id; Splunk holds 128-bit. correlate_trace MUST handle both or agent wrongly reports "no logs found."
- **NATS async trace propagation:** order→notification hop must inject W3C traceparent into NATS envelope explicitly (HTTP propagation is automatic; NATS is not) or async leg shows as disconnected trace.
- **Telemetry fan-out:** traces→Splunk+Datadog (both), logs→Splunk HEC only (DD_LOGS_ENABLED=false to avoid double-billing), metrics→Datadog only. Join key = trace_id/span_id in structured JSON logs. Resource attrs: service.namespace=devops-poc, deployment.environment=demo.
- **maxTurns=30** (NOT below 25): Ollama non-determinism + discover_tools overhead needs up to 25 turns. max_tokens 8192.
- **LLM providers:** ollama (default, /api/chat, args as JSON objects), anthropic (Messages API, AMP injects ANTHROPIC_URL), openai + amp (both /v1/chat/completions, args as JSON strings). ANTHROPIC_URL & LLM_BASE_URL are AMP-injected — never set locally.
- **Postgres schema/DB-per-service** so one service's slow query doesn't muddy another's traces.
- **Ballerina SQL tracing flag** must be on or DB latency is invisible (no child spans).
- **correlate_trace returns links+topology only** (DD APM URL + Splunk SPL + involved services); agent fetches actual data via vendor MCP tools. dd_site from config, never hardcoded.
- **Runbooks are a fixed typed allowlist** (restart-service, clear-cache, disable-chaos, freeze-deploys) — no generic run_cli. disable-chaos = demo recovery lever (calls /chaos/reset).
- **MCP init non-fatal:** if a backend MCP is down at startup, agent warns + continues degraded.
