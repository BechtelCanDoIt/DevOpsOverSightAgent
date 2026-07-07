# DevOps Observability POC (LangChain / A2A) — Plan

A local-first demo: a Python/LangChain orchestrator correlates signals across
Splunk + Datadog (via mock MCP servers) and remediates incidents in a FastAPI
microservice mesh, delegating to two specialist agents over the A2A protocol.
The sibling [`MCP Best Practices Approach`](../../MCP%20Best%20Practices%20Approach/)
is the Ballerina reference this mirrors.

## Phases

| # | Phase | File | Goal |
|---|-------|------|------|
| 0 | Prereqs & decisions | [phase-0-prereqs.md](phase-0-prereqs.md) | uv/Python toolchain, pinned deps, locked decisions |
| 1 | Compose observability stack | [phase-1-compose.md](phase-1-compose.md) | OTel Collector + Postgres/Redis/NATS running; OTLP → debug |
| 2 | Python service mesh + load generator | [phase-2-mesh.md](phase-2-mesh.md) | 7 FastAPI services + load-gen emitting traces/logs/metrics; chaos API |
| 3 | Mock MCP servers | [phase-3-mcp.md](phase-3-mcp.md) | FastMCP Splunk (4 tools) + Datadog (8 tools) with verbatim fixtures |
| 4 | Three agents + A2A | [phase-4-agent.md](phase-4-agent.md) | DataDogAgent + SplunkAgent (A2A) + orchestrator with the approval gate |
| 5 | Demo rehearsal & verification | [phase-5-verify.md](phase-5-verify.md) | End-to-end incident triage in ~5 min |

## Architecture at a glance

```
User / webhook ─► DevOpsOverSightAgent (:18092)
                   ├─ ask_datadog_agent ─A2A─► DataDogAgent (:18101) ─► datadog-mock-mcp (:18401)
                   ├─ ask_splunk_agent  ─A2A─► SplunkAgent  (:18102) ─► splunk-mock-mcp  (:18400)
                   └─ topology__* (in-process: catalog, correlate_trace, runbooks, audit)
                        └─ HumanInTheLoop gate before run_runbook

Mesh (Docker Compose): store customer order inventory invoice payment notification
                        + load-gen  ──OTLP──► OTel Collector ──► debug (or Datadog+Splunk)
```

Full detail: [`../architecture/architecture.md`](../architecture/architecture.md).
Status of the build is tracked as checkboxes inside each phase file.
