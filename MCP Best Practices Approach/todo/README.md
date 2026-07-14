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
| 6 | MCP expansion — WSO2 products + K8s/Docker | [phase-6-mcp-expansion.md](phase-6-mcp-expansion.md) | Federate apim-mcp/mi-mcp/is-mcp (mock-first, live-flag), Kubernetes MCP (read-only), Docker MCP (evaluated, deferred), optional `--profile wso2` real-product containers |
| 7 | Skills & smarter runbook selection | [phase-7-skills-runbooks.md](phase-7-skills-runbooks.md) | Metadata-driven `suggest_runbooks`, server-side `health_report`/`top_issues`/`list_deployments` aggregation, agent chat-command + HTTP skill shortcuts |

## Architecture at a glance

```
┌────────────────────────────────────────────────────────────────────┐
│  WSO2 Agent Manager (Kubernetes, via k3d)                          │
│    Ballerina agent  ── ballerinax/jaeger (OTel traces)             │
│    (LLM tool-use loop: Anthropic Claude | local Ollama)            │
│        │                                                           │
│        └─ ONE MCP client ─► MCP Proxy   (agent NEVER talks to      │
│           BALLERINA_TOPOLOGY_MCP_URL     a backend directly)       │
└────────────────────────────────────────────────────────────────────┘
                        │  host.k3d.internal:8290
                        ▼
┌────────────────────────────────────────────────────────────────────┐
│  Docker Compose stack (local)                                      │
│                                                                    │
│  MCP Proxy (:8290) — federates backends + routes each              │
│  namespaced tool call to its origin; owns topology/                │
│  correlation/runbooks/skills locally:                              │
│     ├─ Splunk MCP   :8400  logs                [required]          │
│     ├─ Datadog MCP  :8401  metrics / APM       [required]          │
│     ├─ apim-mcp     :8402  WSO2 APIM           [mock|live]         │
│     ├─ mi-mcp       :8403  WSO2 MI             [mock|live]         │
│     ├─ is-mcp       :8404  WSO2 IS             [mock|live]         │
│     └─ k8s-mcp      :8405  Kubernetes (RO)  [--profile infra-mcp]  │
│                                                                    │
│  store ─► inventory                                                │
│  order ─┬─► customer   (validate)                                  │
│         ├─► inventory  (reserve)                                   │
│         ├─► payment    (→ mock-bank)                               │
│         ├─► invoice    (bill)                                      │
│         └─► notification  (async via NATS)                         │
│  (7 services: store customer order inventory invoice               │
│               payment notification — sources in generate/)         │
│                                                                    │
│  load-gen (drives 5 domains, chaos toggles)                        │
│  OTel Collector ─► Splunk HEC  +  Datadog Agent ─► Datadog         │
└────────────────────────────────────────────────────────────────────┘
```

The agent opens exactly one MCP connection — to the **MCP Proxy** — and the proxy federates every backend behind it (`BackendDef` rows in `federation.bal`). Splunk/Datadog are the two `required` backends; apim/mi/is are Ballerina-authored WSO2-product wrappers (mock-first, live-mode flag); k8s is off-the-shelf and read-only; Docker was evaluated and deferred. Adding a backend is a table row, not new agent or routing code. See [`architecture.md`](../architecture/architecture.md) for the full diagram.

## Key decisions captured during planning

- **Hybrid deployment**: services + MCP servers local in Docker Compose; telemetry ships to Splunk Cloud trial + Datadog SaaS trial. Reason: Splunk Enterprise in a container is heavy and unrealistic; Datadog has no local mode.
- **Mesh, not single service**: correlation across services is the demo's whole point. One service can't demonstrate it.
- **Single OTel Collector** as the unified telemetry shipper instead of separate vendor agents.
- **Agent runtime is Ballerina** (full-stack Ballerina, overriding Phase 0's Python decision). The agent calls Anthropic Claude directly via HTTP using a native tool-use loop (no SDK required). Ballerina's OTel (`ballerinax/jaeger` + `ballerinax/prometheus`) covers observability. The agent is observable via its own traces in Datadog/Jaeger, completing the "agent watching the workload" story. For LLM flexibility, the agent supports both **Anthropic Claude** (direct API) and **local Ollama** (`qwen3.5:9b` or compatible) via `LLM_PROVIDER` env var — Ollama is creds-free for demos.
- **MCP scope**: lookup + correlation + scoped runbook execution (no raw infra control).
- **Demo headline**: incident triage — alert → agent diagnoses → optional runbook.
- **Write guardrail (Phase 6/7)**: reads federate through `discover_tools`/`routeToolCall` for every backend; writes (restart/scale) run ONLY via `topology__run_runbook`'s direct backend-call path, gated behind `K8S_WRITE_ENABLED` (default off). New WSO2-product MCP servers follow a **mock-first, live-flag** pattern — deterministic fixtures by default, a `MODE=live` env flip to call the real product once creds/URLs are supplied.

## Open questions to resolve in Phase 0

1. Splunk Cloud trial vs. local Splunk Enterprise container — confirm network access at demo venue
2. Datadog trial account API key — who provisions
3. Local Kubernetes for Agent Manager: kind, k3d, or Docker Desktop's built-in?
4. Approved-software gate: who signs off Docker, Ballerina, kind/k3d, Helm?
