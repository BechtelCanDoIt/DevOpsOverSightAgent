# DevOps Observability & Correlation POC — Plan

A local-first demo that wires up real observability backends (Splunk + Datadog), a Ballerina-based microservice mesh with traffic generation, and an agent that correlates signals across them via MCP. The agent runs under **WSO2 Agent Manager**.

## Phases

| # | Phase | File | Goal |
|---|-------|------|------|
| 0 | Prereqs & approved software check | [phase-0-prereqs.md](phase-0-prereqs.md) | Verify Docker, Ballerina, Agent Manager access; lock decisions |
| 1 | Docker Compose observability stack | [phase-1-compose.md](phase-1-compose.md) | Splunk + Datadog + OTel + supporting infra running locally |
| 2 | Ballerina service mesh + load generator | [phase-2-ballerina.md](phase-2-ballerina.md) | Realistic mesh emitting traces/logs/metrics |
| 3 | Ballerina MCP server | [phase-3-mcp.md](phase-3-mcp.md) | Topology + correlation + scoped runbook tools |
| 4 | Ballerina agent (Compose + optional AMP) | [phase-4-agent.md](phase-4-agent.md) | Ballerina agent w/ Claude tool loop, runs in Compose (guaranteed) or AMP (bonus); supports Anthropic + local Ollama LLM |
| 5 | Demo rehearsal & verification | [phase-5-verify.md](phase-5-verify.md) | End-to-end incident triage demo |

## Architecture at a glance

```
┌──────────────────────────────────────────────────────────────────┐
│  WSO2 Agent Manager (Kubernetes, via k3d)                        │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  Ballerina agent  ── ballerinax/jaeger (OTel traces)    │    │
│  │  (Claude tool loop)                                      │    │
│  │    │  LLM: Anthropic Claude or local Ollama             │    │
│  │    │                                                      │    │
│  │    ├── Splunk MCP        (logs)                          │    │
│  │    ├── Datadog MCP       (metrics, APM traces)           │    │
│  │    └── Ballerina MCP     (topology, correlation, runbooks)│    │
│  └──────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────┘
                              │
              ────────────────┼────────────────
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Docker Compose stack (local)                                    │
│                                                                  │
│   store ─► inventory                                             │
│   order ─┬─► customer   (validate)                               │
│          ├─► inventory  (reserve)                                │
│          ├─► payment    (→ mock-bank)                            │
│          ├─► invoice    (bill)                                   │
│          └─► notification  (async via NATS)                      │
│   (7 services: store customer order inventory invoice            │
│                payment notification — sources in generate/)      │
│                                                                  │
│   load-gen (Ballerina worker — drives 5 domains, chaos toggles)  │
│   OTel Collector ──► Splunk HEC                                  │
│                  └─► Datadog Agent ──► Datadog SaaS              │
│   Ballerina MCP server (HTTP/SSE on :8290)                       │
└──────────────────────────────────────────────────────────────────┘
```

## Key decisions captured during planning

- **Hybrid deployment**: services + MCP servers local in Docker Compose; telemetry ships to Splunk Cloud trial + Datadog SaaS trial. Reason: Splunk Enterprise in a container is heavy and unrealistic; Datadog has no local mode.
- **Mesh, not single service**: correlation across services is the demo's whole point. One service can't demonstrate it.
- **Single OTel Collector** as the unified telemetry shipper instead of separate vendor agents.
- **Agent runtime is Ballerina** (full-stack Ballerina, overriding Phase 0's Python decision). The agent calls Anthropic Claude directly via HTTP using a native tool-use loop (no SDK required). Ballerina's OTel (`ballerinax/jaeger` + `ballerinax/prometheus`) covers observability. The agent is observable via its own traces in Datadog/Jaeger, completing the "agent watching the workload" story. For LLM flexibility, the agent supports both **Anthropic Claude** (direct API) and **local Ollama** (`qwen3.5:9b` or compatible) via `LLM_PROVIDER` env var — Ollama is creds-free for demos.
- **MCP scope**: lookup + correlation + scoped runbook execution (no raw infra control).
- **Demo headline**: incident triage — alert → agent diagnoses → optional runbook.

## Open questions to resolve in Phase 0

1. Splunk Cloud trial vs. local Splunk Enterprise container — confirm network access at demo venue
2. Datadog trial account API key — who provisions
3. Local Kubernetes for Agent Manager: kind, k3d, or Docker Desktop's built-in?
4. Approved-software gate: who signs off Docker, Ballerina, kind/k3d, Helm?
