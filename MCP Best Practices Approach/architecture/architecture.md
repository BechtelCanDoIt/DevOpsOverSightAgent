# Architecture — DevOps Observability POC

This POC demonstrates an AI agent that diagnoses and remediates a production-style incident by
correlating signals across **two required observability backends** plus an expanding set of
**optional federated backends**. A Ballerina retail microservice mesh emits traces, logs, and
metrics through a **single OpenTelemetry Collector** that fans out to **Splunk** (logs/traces) and
**Datadog** (APM/metrics). A **Ballerina agent** calls a configurable LLM via HTTP using a native
tool-use loop — **local Ollama** (creds-free, default), **Anthropic Claude**, **OpenAI**, or **WSO2
AMP** (switched via `LLM_PROVIDER` env var) — and reaches all observability signal sources through a
single **MCP Proxy** (`:8290`). The proxy owns the service catalog, cross-system trace correlation,
scoped remediation runbooks, and cross-backend "skills" (health/top-issues aggregation) locally,
and routes each backend's tool calls to a data-driven `BackendDef` row — Splunk and Datadog are
required and always-on (mock MCPs by default; swapped for official SaaS MCPs when creds arrive);
three Ballerina-authored WSO2-product wrappers (APIM/MI/IS, mock-first with a live-mode flag) and an
off-the-shelf, read-only Kubernetes MCP federate in the same way, optionally, with zero proxy code
change per backend (Phase 6/7 — see §5). The headline scenario: an operator injects chaos into
`payment-service`, a Datadog monitor fires, and the agent investigates end-to-end, proposes a
runbook, and — after human approval — remediates and writes a postmortem.

> This document is the deep-dive architecture reference. For component-by-component descriptions and
> getting-started instructions, see the root [`README.md`](README.md). The authoritative
> implementation specs are the phase docs under [`todo/`](todo/) (see [References](#14-references)).

---

## Contents

- [Architecture — DevOps Observability POC](#architecture--devops-observability-poc)
  - [Contents](#contents)
  - [1. System overview](#1-system-overview)
  - [2. High-level architecture](#2-high-level-architecture)
  - [3. Workload service mesh](#3-workload-service-mesh)
    - [Topology](#topology)
    - [Dependency table](#dependency-table)
    - [Per-service common surface](#per-service-common-surface)
    - [Traffic generator](#traffic-generator)
  - [4. Observability \& telemetry pipeline](#4-observability--telemetry-pipeline)
    - [Fan-out rationale](#fan-out-rationale)
    - [Supporting components](#supporting-components)
    - [The structured-log join key](#the-structured-log-join-key)
  - [5. MCP \& agent tier](#5-mcp--agent-tier)
    - [MCP Proxy and backends](#mcp-proxy-and-backends)
    - [MCP Proxy tool catalog](#mcp-proxy-tool-catalog)
    - [Tool-loading approach and scaling note](#tool-loading-approach-and-scaling-note)
    - [Optional API Manager MCP Gateway](#optional-api-manager-mcp-gateway)
    - [Agent self-observability (the meta-win)](#agent-self-observability-the-meta-win)
  - [6. Cross-system correlation](#6-cross-system-correlation)
    - [The 64-bit vs 128-bit trace-ID caveat](#the-64-bit-vs-128-bit-trace-id-caveat)
  - [7. Incident-response flow (headline demo)](#7-incident-response-flow-headline-demo)
  - [8. Trace-context propagation](#8-trace-context-propagation)
  - [9. Key design decisions](#9-key-design-decisions)
  - [10. Known gotchas \& risks](#10-known-gotchas--risks)
  - [11. Repository layout](#11-repository-layout)
  - [12. Single-agent + MCP Proxy vs. agent-to-agent (A2A)](#12-single-agent--mcp-proxy-vs-agent-to-agent-a2a)
    - [The two topologies](#the-two-topologies)
    - [Why the proxy wins *for this system*](#why-the-proxy-wins-for-this-system)
    - [Where A2A *would* be right](#where-a2a-would-be-right)
    - [The nuance: trust boundary ≠ reasoning boundary](#the-nuance-trust-boundary--reasoning-boundary)
    - [Migration path is clean](#migration-path-is-clean)
  - [13. Production architecture (enterprise — "ACME")](#13-production-architecture-enterprise--acme)
    - [What changes from POC → production](#what-changes-from-poc--production)
    - [What stays the same (the durable bets)](#what-stays-the-same-the-durable-bets)
  - [14. References](#14-references)

---

## 1. System overview

The system is built in two tiers that run on different runtimes and are stitched together over the
host network:

| Tier | Runtime | Contains | Built in |
|------|---------|----------|----------|
| **Workload + observability** | Docker Compose (bridge network `devops-poc`) | 7-service Ballerina mesh, `load-gen`, OTel Collector, Datadog Agent, NATS, Postgres, Redis, (optional Jaeger), MCP Proxy, mock MCP backends | Phases 1–3 |
| **Agent** | Docker Compose (same stack) or Kubernetes (kind, optional) | Ballerina agent (OTel-instrumented), configurable LLM backend (`LLM_PROVIDER`); connects to a single MCP Proxy | Phase 4 |

Telemetry leaves the Compose tier for two SaaS backends — **Splunk Cloud trial** and **Datadog
SaaS** — neither of which runs locally. The agent tier sits above both and treats Splunk, Datadog,
and the mesh's own topology service as MCP tool surfaces.

---

## 2. High-level architecture

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│  KUBERNETES (kind)  —  Agent tier under WSO2 Agent Manager                             │
│                                                                                        │
│   ┌──────────────────────────────────────────────────────────────────────────────┐   │
│   │  Ballerina agent  (LLM via HTTP tool-use loop — configurable LLM_PROVIDER)   │   │
│   │     src: code/agent/                                                      │   │
│   │     OTel: ballerinax/jaeger (OTLP gRPC) + ballerinax/prometheus              │   │
│   │     LLM: Ollama (default, creds-free) | Anthropic | OpenAI | AMP             │   │
│   │     └── single MCP client ──► MCP Proxy (:8290)                              │   │
│   │  (mcp_client.bal)              src: code/mcp/mcp-proxy/                     │   │
│   └──────────────────────────────────────────────────────────────────────────────┘   │
│                      │ (optional) WSO2 API Manager MCP Gateway: auth, rate-limit, audit│
└──────────────────────┼─────────────────────────────────────────────────────────────────┘
                       │  reached via host.k3d.internal:8290
┌──────────────────────┼─────────────────────────────────────────────────────────────────┐
│  DOCKER COMPOSE  (bridge network: devops-poc)  —  Workload + observability tier        │
│                       ▼                                                                 │
│   MCP Proxy (Streamable HTTP, :8290)   src: code/mcp/mcp-proxy/                        │
│   ├── topology/correlation/runbook/skills tools (local, owns service catalog)          │
│   ├── required:  splunk-mock-mcp :8400  +  datadog-mock-mcp :8401  (or real MCPs)      │
│   └── optional, federated (Phase 6 — zero proxy code change per backend):              │
│        ├─ apim-mcp :8402 · mi-mcp :8403 · is-mcp :8404  (mock-first, MODE=live)        │
│        ├─ k8s-mcp :8405  (read-only, off-the-shelf, --profile infra-mcp)               │
│        └─ docker MCP — evaluated, deferred (opaque single-tool shape)                  │
│                                                                                        │
│   ┌─ Workload mesh (7 services + load-gen) ──────────────────────────────────────┐    │
│   │  store  customer  order  inventory  invoice  payment  notification            │    │
│   │  load-gen drives the 5 front-facing domains; payment/notification transitive  │    │
│   └───────────────────────────────────────────────────────────────────────────────┘   │
│          │ OTLP gRPC :4317 / HTTP :4318                                                 │
│          ▼                                                                              │
│   otel-collector  ──── traces ───►  Datadog  +  Splunk                                  │
│        │           ──── logs   ───►  Splunk (HEC)                                       │
│        │           ──── metrics ──►  Datadog                                            │
│        ├──► datadog-agent ──► Datadog SaaS  (APM + metrics; DD_LOGS_ENABLED=false)      │
│        └──► splunk_hec exporter ──► Splunk Cloud trial   (Splunk NOT in compose)        │
│                                                                                        │
│   Infra:  nats (async bus)   postgres (shared, schema-per-service)   redis (inv cache) │
│           jaeger (dev-only, optional local trace inspection)                           │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

**How the tiers connect.** The agent runs in k3d (via the AMP quick-start container); the MCP Proxy, mock MCP backends, and workload run in Compose on the host. The agent pod reaches the proxy via `host.k3d.internal:8290` — a hostname k3d registers in every pod that resolves to the Docker host. MCP port `8290` is published to the host in `docker-compose.yml`. To swap in real SaaS MCPs, set `SPLUNK_MCP_URL` and `DATADOG_MCP_URL` on the proxy — no agent code changes required. The optional backends follow the same pattern: `{APIM,MI,IS}_MCP_MODE=live` flips each WSO2-product wrapper from its mock fixtures to the real product; `K8S_MCP_URL` (set automatically by `make infra-up`) federates the Kubernetes MCP under `--profile infra-mcp` — none of this touches the agent.

---

## 3. Workload service mesh

A realistic retail mesh — the whole point is **cross-service correlation, blast-radius, and
"which downstream caused this."** Each source directory `code/generate/<x>/` maps to service name
`<x>-service` via `OTEL_SERVICE_NAME` (the `-service` suffix is load-bearing — Phases 3 & 5 reference
services by that exact name).

### Topology

```
load-gen ─► store, customer, order, invoice, inventory
order ─┬─► customer  (validate)
       ├─► inventory (reserve) ─► redis ─► postgres (on miss)
       ├─► payment  (charge)   ─► mock-bank (in-process mock)
       ├─► invoice  (bill)
       └─NATS─► notification   (confirm)   [async — explicit W3C trace-context in envelope]
store ─► inventory
{order, customer, invoice, store} ─► postgres
```

### Dependency table

| Service | Role | Upstream (callers) | Downstream (callees) | Infra | Chaos modes | LB target |
|---------|------|--------------------|-----------------------|-------|-------------|:---------:|
| `store-service` | Storefront / catalog browse | load-gen | `inventory`, Postgres | Postgres | latency, 500 | ✅ |
| `customer-service` | Customer profiles / accounts | load-gen, `order` | Postgres | Postgres | latency, 500 | ✅ |
| `order-service` | Front-door `POST /orders` orchestrator | load-gen | `customer`, `inventory`, `payment`, `invoice`; NATS → `notification`; Postgres | Postgres | DB slow query, 500 on validation | ✅ |
| `inventory-service` | Reserves stock | load-gen, `order`, `store` | Redis → Postgres (on miss) | Redis + Postgres | cold-cache latency spike | ✅ |
| `invoice-service` | Generates invoice / billing record | load-gen, `order` | Postgres | Postgres | latency, 500 | ✅ |
| `payment-service` | Charges card (mocked) | `order` | in-process **mock-bank** (dummy) | — | **timeout, sporadic 502** (headline) | indirect |
| `notification-service` | Order confirmation | `order` (via NATS) | — (NATS subscriber) | NATS | slow consumer / backlog | indirect |
| `load-gen` | Drives traffic + holds chaos one-liners | — | all 5 front-door domains | — | n/a (it is the driver) | — |

The five **front-facing domains** (`customer, order, invoice, inventory, store`) are driven directly
by `load-gen`; `payment` and `notification` are exercised transitively through `order`. This shape
gives the demo a synchronous fan-out (`order → customer/inventory/payment/invoice`) plus one async
hop (`order → notification` over NATS) — the minimum interesting shape for blast-radius and
async-correlation stories.

### Per-service common surface

Every service (not `load-gen`) exposes, beyond its business routes:

| Endpoint | Purpose |
|----------|---------|
| `GET /health` | Liveness + quick check; probed by the MCP Proxy `get_service_health(name)` tool |
| `POST /chaos/latency` | Body `{ "ms": 2000, "duration_s": 60 }` — inject latency for a window |
| `POST /chaos/error` | Body `{ "rate": 0.3, "status": 502 }` — return that status for a fraction of requests |
| `POST /chaos/reset` | Restore normal behaviour (driven by the `disable-chaos` runbook) |

The `/chaos/*` endpoints are **token-gated and internal-network only** — they are the levers the
Phase 5 demo pulls to manufacture the incident the agent diagnoses.

### Traffic generator

`code/generate/load-gen/` is a long-lived Ballerina worker (not a service). It reads a YAML pattern file
(`baseline.yaml`, `spike.yaml`, `regression.yaml`) defining baseline RPS, ramp shape, and spike
windows, plus per-domain flow definitions. It is selected with `--pattern baseline|spike|regression`
and defaults to `baseline`. It emits its own OTel spans so the generated load is itself visible in
Datadog.

---

## 4. Observability & telemetry pipeline

A **single OTel Collector** (`otel/opentelemetry-collector-contrib`) is the unified shipper. All
Ballerina services emit OTLP to it; the Collector fans each signal type to the backend that owns it.

```
Ballerina services  ──OTLP gRPC :4317 / HTTP :4318──►  otel-collector
                                                          │
                          ┌───────────────────────────────┼───────────────────────────────┐
                          ▼                                ▼                                ▼
                    TRACES → Datadog + Splunk        LOGS → Splunk (HEC)          METRICS → Datadog
                          │            │                   │                            │
                          │   splunk_hec exporter ─────────┘                            │
                          │                                                             │
                    datadog exporter ──────────────────────────────────────────────────┘
                          │
                          └──► (also) datadog-agent ──► Datadog SaaS (APM + container metrics)
```

### Fan-out rationale

| Signal | Destination | Why |
|--------|-------------|-----|
| **Traces** | **Both** Splunk + Datadog | Datadog is the APM/trace UI; Splunk holds the trace-correlated logs. Sending traces to both lets the agent pivot between them by `trace_id`. |
| **Logs** | **Splunk only** (HEC) | Splunk is the log-of-record. `DD_LOGS_ENABLED=false` on the Datadog Agent keeps logs out of Datadog to avoid double-billing. |
| **Metrics** | **Datadog only** | Datadog is the metrics-of-record and drives the monitor that fires the incident alert. |

The Collector adds resource attributes `deployment.environment=demo` and
`service.namespace=devops-poc`, and runs a `batch` processor plus a `memory_limiter` so it survives
load tests.

### Supporting components

| Component | Role | Exposure |
|-----------|------|----------|
| `datadog-agent` | Ships APM traces + container metrics to Datadog SaaS (`DD_APM_ENABLED=true`, `DD_APM_NON_LOCAL_TRAFFIC=true`, `DD_LOGS_ENABLED=false`) | internal-only |
| `nats` | Async event bus for `order → notification` | internal-only |
| `postgres` | Shared backing store, **schema/DB per service** (`order`, `customer`, `invoice`, `store`) so a slow query in one does not muddy others | host 5432 for poking |
| `redis` | `inventory-service` cache; misses fall back to Postgres (drives the cold-cache latency story) | internal-only |
| `jaeger` | Local trace inspection during build — **dev-only, optional**, removed for the customer demo | UI 16686 |
| **Splunk** | Log/trace backend — **NOT in compose**; Splunk Cloud trial reached via the Collector's `splunk_hec` exporter | SaaS |

### The structured-log join key

Each Ballerina service emits **structured JSON logs with `trace_id` and `span_id` injected** into
every line. This is the join key: a trace seen in Datadog APM and the log lines for the same request
in Splunk share the same `trace_id`, which is what makes cross-system correlation possible (see §6).

---

## 5. MCP & agent tier

The agent is **Ballerina** (same as the workload mesh and MCP Proxy — the entire stack is Ballerina). It calls the LLM directly via HTTP using a native tool-use loop; no SDK required. The LLM backend is selected by the `LLM_PROVIDER` env var: `ollama` (default, creds-free, local Ollama at `OLLAMA_BASE_URL`), `anthropic` (Anthropic Messages API; AMP proxy via `ANTHROPIC_URL`), `openai`, or `amp` (WSO2 AMP AI gateway). OTel instrumentation uses the same `ballerinax/jaeger` + `ballerinax/prometheus` pattern as the mesh services by default, with an optional `ballerinax/amp` exporter — see §Agent self-observability below.

### MCP Proxy and backends

The agent connects to a **single MCP Proxy** (`:8290`). The proxy owns the service catalog tools locally and routes Splunk/Datadog tool calls to the configured backends. Swapping from mock to real SaaS MCPs requires only an env-var change on the proxy.

| Component | Origin | Hosting / transport | Key tools | Config |
|-----------|--------|---------------------|-----------|--------|
| **MCP Proxy** | Custom (this repo) | **Host-local** in Compose, Streamable HTTP `:8290` | topology / correlation / runbooks (catalog below) + proxied Splunk/Datadog tools | `code/mcp/mcp-proxy/`; client `code/agent/mcp_client.bal` |
| **Splunk MCP** | Official — *MCP Server for Splunk platform* (Splunkbase 7931) | App on **your Splunk Cloud**; Streamable HTTP; MCP bearer token (RBAC `mcp_tool_execute`). Default: `splunk-mock-mcp :8400` | `splunk_run_query` (SPL), `splunk_get_indexes`, `splunk_get_knowledge_objects` | env `SPLUNK_MCP_URL` on the proxy |
| **Datadog MCP** | Official — *Datadog MCP Server* (Bits AI) | **Remote-hosted** `mcp.datadoghq.com` (regional per `DD_SITE`). Default: `datadog-mock-mcp :8401` | `get_datadog_metric`, `search_datadog_error_tracking_issues`, `get_datadog_trace`, `search_datadog_logs`, `search_datadog_monitors` | env `DATADOG_MCP_URL` on the proxy |

Splunk MCP knows logs; Datadog MCP knows metrics and traces. **Neither knows your service catalog,
dependency graph, owners, or runbooks** — the MCP Proxy fills that gap with local tools, and
because it is Ballerina it can also *act* (hit chaos endpoints, restart containers) to remediate.

**N-backend federation (Phase 6/7):** the two-backend table above is the always-on demo path, but the proxy's `federation.bal` generalizes federation to any number of backends via a data-driven `BackendDef` row (label, env key, default URL, `required` flag, `allowTools`/`denyTools` glob patterns) — adding a backend is a table row, not new routing code. Splunk/Datadog are the only `required: true` rows. Three Ballerina-authored WSO2-product wrappers (`apim-mcp`/`mi-mcp`/`is-mcp`, mock-first with a `MODE=live` flag — same pattern as Splunk/Datadog) and two off-the-shelf infra servers (`k8s-mcp` federated read-only; a Docker MCP spike evaluated and deferred — its one opaque `docker` tool doesn't fit the guardrail's name-pattern filtering) federate in the same way, optionally, with zero cost when their URL is unset. Full backend/port table in [`README.md`](../README.md#federated-backends-phase-6).

**Write guardrail:** a backend's `allowTools`/`denyTools` glob filter runs at *registration* time — a filtered tool is simply never added to the discoverable registry, so it can be neither discovered nor called by the agent, full stop. Real write actions (`restart-service`/`scale-service`'s docker/k8s paths) run through a separate direct-call function the registry-based router never reaches, gated behind `K8S_WRITE_ENABLED` (default off). This is the same "reads federate, writes only via runbooks" principle the two-backend design already established — Phase 6/7 just generalized its enforcement point from one `if` per backend to one filter function that applies uniformly.

### MCP Proxy tool catalog

`tools/list` returns **only `discover_tools` plus the 15 `topology__*` tools** — every federated backend's tool schemas are hidden in the server-side registry until the agent calls `discover_tools(query)`. Tool names below are exactly as the agent sees and calls them.

| Group | Tool (agent-facing name) | Inputs | Returns |
|-------|--------------------------|--------|---------|
| **Discovery** | `discover_tools` | `query` | JSON manifest bundle — top-k tool schemas matching the query; agent calls `absorbDiscovered` to add them to its active set for subsequent turns |
| **Lookup / topology** | `topology__lookup_service` | `name` | `{ owner, repo, runbook_ids, sla, health_endpoint, dependencies }` |
| | `topology__get_dependencies` | `name`, `direction` (`upstream`/`downstream`/`both`) | Adjacency list — must match the §3 topology exactly |
| | `topology__list_services` | (none) | All known services + `last_seen` |
| | `topology__get_service_health` | `name` | Probes `/health` live; returns status + latency |
| **Correlation** | `topology__correlate_trace` | `trace_id` | Datadog APM URL + pre-filtered Splunk search URL + involved services — links + topology only; the agent follows up with `splunk__splunk_run_query` / `datadog__get_datadog_trace` to fetch live data |
| | `topology__find_recent_deploys` | `service`, `lookback` | Recent deploys (stub deploy log) — "did something change?" |
| | `topology__find_related_incidents` | `service`, `lookback` | Past incidents (stub local SQLite) — learning-from-history |
| **Runbooks** | `topology__list_runbooks` | (none) | Array of `{ id, name, description, params_schema, symptoms, category, riskLevel, automatable }` |
| | `topology__run_runbook` | `id`, `params` | **SSE-streaming** progress of runbook execution |
| | `topology__suggest_runbooks` **(Phase 7)** | `service`, `diagnosis` | Top-3 ranked `{ id, name, score, riskLevel, automatable, rationale, paramsSchema }` — see §Runbook selection scoring below |
| **Skills (Phase 7)** | `topology__health_report` | `product?` | `{ overall, generatedAt, sections }` — parallel fan-out across mesh + every federated WSO2-product backend |
| | `topology__top_issues` | `count?`, `product?` | Ranked issues across mesh/Datadog/Splunk/APIM/MI/IS/K8s |
| | `topology__list_deployments` | (none) | Deployment cache — 7 mesh services + wso2am/wso2mi/wso2is |
| **Ops** | `topology__get_audit_log` | (none) | Recent runbook execution audit entries |
| | `topology__get_deploy_freeze_status` | (none) | Current deploy-freeze flag state |

**Initial runbooks** (live as Ballerina functions in `mcp-proxy/runbooks.bal`, each appending to an
`audit.log`):

| Runbook | Action |
|---------|--------|
| `restart-service` | Restart a container/pod — real docker/k8s write path (gated behind `K8S_WRITE_ENABLED`) or the pre-existing stub |
| `clear-cache` | Redis `FLUSHDB` on `inventory-service`'s cache |
| `disable-chaos` | Calls `/chaos/reset` on a target service — **most-used in the demo** |
| `freeze-deploys` | Sets a flag in the stub deploy registry |
| `scale-service` **(Phase 7)** | Adjusts a Kubernetes Deployment's replica count — same real/stub gating as `restart-service` |

### Runbook selection scoring (Phase 7)

`topology__suggest_runbooks {service, diagnosis}` replaces unaided LLM judgment with a deterministic score: an **applicability filter** first drops any runbook not listed for that service (unless its `category` is `process`, which is always eligible — e.g. `freeze-deploys`). Surviving runbooks score `+3` per diagnosis word that exactly matches one of the runbook's `symptoms` words, `+2` for a substring match against the name/description, `+1` for a 4-character stem match — then `+4` if the runbook is catalog-listed for this service, `+2` if `automatable`, and `−2×(riskLevel−1)` as a risk penalty. Ties break in favor of the lower `riskLevel`. This is intentionally the same keyword-tiering shape as the tool-discovery scorer in §Tool-loading approach — one scoring idiom, two applications.

The service catalog is a static in-code map in `code/mcp/mcp-proxy/catalog.bal` enumerating all
seven mesh services with `dependencies` matching the §3 topology; production would discover from a
real CMDB.

### Tool-loading approach and scaling note

The agent starts each `investigate()` / `chat()` call with only the `discover_tools(query)` tool in context — **lazy tool loading (Pattern 2 from the MCP scaling guide)**. The agent calls `discover_tools` with a natural-language description of what it needs; the proxy scores all registered tool manifests (across the topology, Splunk, and Datadog namespaces) and returns the top-k matches, which are injected for that turn only. This keeps the initial context window small regardless of how many tools the real Splunk and Datadog MCPs expose.

The tool registry is backed by a keyword-based scorer today; a pgvector + `nomic-embed-text` upgrade (already in the stack) is the planned improvement for production-grade routing accuracy. This work is tracked in the Phase 4 exit criteria.

### Server-side aggregation — the "skills" pattern (Phase 7)

`topology__health_report` and `topology__top_issues` answer a class of question — "how's everything?", "what's broken?" — that would otherwise cost the agent one `discover_tools` + one call *per backend*, several LLM turns for a single answer. Instead the proxy does the fan-out itself: one `start`/`wait` future per mesh service and per connected WSO2-product backend, all in flight concurrently, so wall-clock is bounded by the slowest single probe, not the sum. A **disconnected** backend short-circuits to an `UNAVAILABLE` section before ever opening a future — checked via `isBackendConnected` — so an optional backend that's simply not configured costs nothing. `topology__top_issues` follows the same shape but is deliberately not just health checks: mesh DOWN probes, Datadog alerting monitors + error-tracking issues, a fixed-SPL Splunk error-count query, and each WSO2 product's own anomaly shape (BLOCKED API, INACTIVE message processor, disconnected user store) all score into one ranked list.

The agent exposes both **without the LLM loop at all** — `GET /health-report`/`GET /top5` on the agent, plus `Health`/`Top5` chat-command shortcuts that pattern-match the message text before it ever reaches `runConfiguredLlm`. This is deliberate: these are deterministic lookups, not reasoning tasks, so paying for an LLM turn (and its non-determinism) to answer them would be pure overhead. See `todo/phase-7-skills-runbooks.md` and `todo/phase-4-agent.md` §4.9.

### Optional API Manager MCP Gateway

The **MCP Proxy** (the agent's single entry point) may be fronted by the **WSO2 API Manager MCP Gateway**, which gives **auth, rate-limiting, and audit "for free."** The agent's single `BALLERINA_TOPOLOGY_MCP_URL` points at the gateway URL; the gateway forwards to the proxy, which continues to federate the Splunk/Datadog backends as normal.

### Agent self-observability (the meta-win)

The agent watching the workload is itself watched — two ways, both driven purely by config:

- **Default:** the agent's OTel spans flow through the same OTel Collector as the mesh (`ballerinax/jaeger`, `[ballerina.observe].tracingProvider = "jaeger"` in `code/agent/Config.toml`) — its reasoning trace, per-LLM-call latency, and tool-call durations land in Datadog alongside the workload it's diagnosing.
- **Direct to AMP:** the official [`ballerinax/amp`](https://central.ballerina.io/ballerinax/amp) observability extension (imported in `code/agent/tracing.bal`) can instead ship the agent's trace straight to the **AMP Console's Traces view** — root span with end-to-end latency, LLM spans with token counts, tool spans with inputs/outputs. Switch by setting `tracingProvider = "amp"` (env override: `BAL_CONFIG_VAR_BALLERINA_OBSERVE_TRACINGPROVIDER=amp`, or `AMP_TRACING_PROVIDER=amp` in `compose/.env`) — no code change. See the README's [Agent tracing → the AMP Console](../README.md#agent-tracing--the-amp-console-optional) and WSO2's [Observe Your First Agent](https://wso2.github.io/agent-manager/docs/v0.18.x/tutorials/observe-first-agent/) tutorial.

Caveat either way: exported spans may capture request bodies — bearer tokens must be scrubbed (Agent Manager's redaction config, or the collector pipeline) before they reach the trace store.

---

## 6. Cross-system correlation

A single request produces a Datadog APM trace **and** Splunk log lines that share the same
`trace_id`. `correlate_trace(trace_id)` is the bridge:

```
                         agent has a trace_id (from a Datadog sample trace)
                                          │
                                          ▼
               MCP Proxy: correlate_trace(trace_id)   ← links + topology only
                                          │
        ┌─────────────────────────────────┼─────────────────────────────────┐
        ▼                                 ▼                                   ▼
 Datadog APM deep-link          Splunk search URL / SPL           involved services
 app.{dd_site}/apm/             index=* trace_id={id}             (from static catalog)
   trace/{trace_id}             (pre-filled)                              │
        ▼                                 ▼                                  │
  MCP Proxy routes to:           MCP Proxy routes to:                       │
  Datadog MCP backend            Splunk MCP backend                         │
  → get_datadog_trace         → splunk_run_query(SPL)  ◄── agent FETCHES ──┘
```

`correlate_trace` returns **links + topology only** — the Datadog APM URL, the pre-filtered Splunk
search URL/SPL, and the catalog-derived list of involved services. It **does not call vendor REST
APIs**; the agent fetches the actual data through the official MCPs (`get_datadog_trace` on the
Datadog MCP, `splunk_run_query` on the Splunk MCP). The Datadog base URL comes from `dd_site` in a
config file — never hardcoded.

### The 64-bit vs 128-bit trace-ID caveat

Datadog historically uses **64-bit** trace IDs; OTel uses **128-bit**. In the Datadog UI you will see
both `dd.trace_id` (64-bit) and `otel.trace_id` (128-bit). The correlation layer **must handle both
formats** — otherwise the agent searches Splunk (which holds the 128-bit form) with the 64-bit form
Datadog displayed and wrongly concludes "no logs found for this trace." This is the single most
important correctness detail in the whole pipeline.

---

## 7. Incident-response flow (headline demo)

The Phase 5 headline scenario — target runtime **5 minutes** end-to-end. The critical design feature
is the **human-in-the-loop "propose before act" gate**: the agent must call `list_runbooks` and
present its choice before it is allowed to call `run_runbook`.

**This is a code-level gate, not just a prompt convention (Phase 4 §4.9).** `topology__run_runbook` is
never forwarded to the proxy from the agent's LLM-facing dispatcher — every attempt is intercepted,
stored, and answered with a blocked-pending-approval sentinel that halts the tool-use loop immediately
(across all four LLM providers). The only code path able to execute a runbook for real is reached
through a separate `"approve <token>"` / `"deny <token>"` chat message, parsed before the message ever
reaches the LLM. This mirrors the LangChain sibling's `HumanInTheLoopMiddleware` interrupt (see
`todo/phase-4-agent.md` §4.4 for the live before/after reproduction — an earlier prompt-only version of
this gate was caught, on a real Ollama run, autonomously executing `disable-chaos` and `restart-service`
in response to an unrelated question).

```
Operator        payment-svc      Datadog        Agent (Ballerina)            MCP Proxy / Splunk / DD     Human
   │                 │              │                 │                            │                      │
 1.│ inject chaos ──►│              │                 │                            │                      │
   │ (30% 502 + 2s)  │ degrades     │                 │                            │                      │
 2.│                 │ ───metrics──►│ monitor fires    │                            │                      │
   │                 │              │ ──webhook (≤60s)►│                            │                      │
 3.│                 │              │   discover_tools("Datadog metrics") ──────────► manifest bundle        │
   │                 │              │   datadog__get_datadog_metric → error-rate spike                     │
   │                 │              │     └─ identifies payment-service as origin   │                      │
   │                 │              │   topology__get_dependencies("payment-service",                      │
   │                 │              │       "downstream")  ─────────────────────────► blast radius         │
   │                 │              │   discover_tools("Datadog trace APM") ─────────► manifest bundle     │
   │                 │              │   datadog__get_datadog_trace (sample trace_id)│                      │
   │                 │              │   topology__correlate_trace(trace_id) ─────────► Datadog+Splunk URLs │
   │                 │              │   discover_tools("Splunk log 502") ────────────► manifest bundle     │
   │                 │              │     splunk__splunk_run_query ◄── Splunk logs show mock-bank timeouts │
   │                 │              │   topology__find_recent_deploys("payment-svc") ► nothing→rules out  │
   │                 │              │     └─ suspects chaos / external dependency   │   a deploy           │
 ──┼─────────────────┼──────────────┼── PROPOSE-BEFORE-ACT GATE ────────────────────┼──────────────────────┼──
   │                 │              │   topology__list_runbooks → proposes disable-chaos ──────────────►│
 4.│                 │              │                 │                ◄── approves ─┼──────────────────────┤
 5.│                 │              │   topology__run_runbook("disable-chaos",       │                      │
   │                 │◄─/chaos/reset─┤      {service:"payment-service"}) ──SSE──────► streams progress      │
   │                 │ recovers     │                 │                            │                      │
 6.│                 │              │   writes markdown postmortem (slide-ready)    │                      │
```

| Step | Beat | What happens |
|:----:|------|--------------|
| 1 | **Inject** | Operator triggers `payment-service` chaos: 30% 502 rate + 2s latency. Mesh degrades. |
| 2 | **Alert** | Pre-configured Datadog monitor fires within 60s; webhook hits the agent. |
| 3 | **Investigate** | Agent calls `discover_tools` to load Datadog schemas, pulls metrics via `datadog__get_datadog_metric` → identifies `payment-service` spike → `topology__get_dependencies(...,"downstream")` for blast radius → loads trace tools via `discover_tools`, calls `datadog__get_datadog_trace` → `topology__correlate_trace` builds the Splunk search → loads Splunk tools via `discover_tools`, calls `splunk__splunk_run_query` → sees **mock-bank timeouts** → `topology__find_recent_deploys` finds nothing, rules out a deploy → suspects chaos/external dependency. |
| 4 | **Propose / approve** | Agent calls `topology__list_runbooks`, attempts `run_runbook("disable-chaos", ...)` — the code-level gate intercepts it, stores the proposal, and returns an approval token instead of executing; the operator replies `"approve <token>"` in the agent console. |
| 5 | **Remediate** | The approval message reaches `handleApprovalCommand`, the *only* path that calls the proxy's real `topology__run_runbook("disable-chaos", { service: "payment-service" })`; SSE streams progress; chaos resets; mesh recovers. |
| 6 | **Postmortem** | Agent generates a markdown postmortem — what happened, what it did, links to the traces. |

The agent is invoked by a **Datadog monitor → webhook** in the rehearsed live demo (most realistic),
with a **CLI** (`agent investigate --alert-id X`) kept as a fallback. Two additional verified-but-not-
necessarily-live scenarios round out the platform story: **slow-query regression** (`inventory-service`
DB latency → agent diagnoses DB-bound vs network-bound from span breakdowns) and **async backlog**
(`notification-service` slow consumption → agent spots NATS backlog in Datadog, recommends scale-up).

---

## 8. Trace-context propagation

| Hop type | Propagation | Mechanism |
|----------|-------------|-----------|
| **HTTP → HTTP** | **Automatic** | Ballerina's observability module propagates W3C trace-context headers across HTTP calls (e.g. `order → customer/inventory/payment/invoice`, `store → inventory`). |
| **HTTP → NATS → HTTP** | **Explicit** | NATS does not carry HTTP headers. The W3C trace-context **must be explicitly injected into the NATS message envelope** by the publisher (`order`) and extracted by the subscriber (`notification`) — otherwise the async confirmation appears as a disconnected trace. |

```
order  ──(HTTP, auto ctx)──►  customer / inventory / payment / invoice
order  ──publish──►  [ NATS envelope { ...payload, traceparent: "00-<trace>-<span>-01" } ]  ──►  notification
                                       ▲ explicit W3C trace-context injection — built in from day one
```

Postgres calls must also surface as **child spans** — this requires enabling the Ballerina SQL
connector's tracing flag, otherwise DB latency is invisible in the trace.

---

## 9. Key design decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| LLM | **Configurable via `LLM_PROVIDER`** | `ollama` (default, creds-free), `anthropic`, `openai`, `amp`. All four providers implemented in `code/agent/llm_client.bal`; no SDK dependency — calls the provider's HTTP API directly. |
| Local Kubernetes | **k3d** (via AMP quick-start) | AMP quick-start bootstraps its own k3d cluster (`amp-local`); no separate kind setup needed. |
| Splunk deployment | **Splunk Cloud trial** | Splunk Enterprise in a container is heavy and unrealistic; trial reached via the Collector's `splunk_hec` exporter. |
| Telemetry shipper | **Single OTel Collector** | One unified fan-out point instead of separate per-vendor agents. |
| Agent language | **Ballerina** | Full-stack Ballerina — overrides the Phase 0 Python decision. Ballerina OTel (`ballerinax/jaeger` + `ballerinax/prometheus`) covers the observability need; the tool-use loop calls Anthropic directly via HTTP. |
| Workload + MCP language | **Ballerina** | Showcases Ballerina's integration story for the mesh and the MCP Proxy. |
| Mesh shape | **Hybrid (7 services)** | Kept the 4 spec services (`order, payment, inventory, notification`) and added `customer, invoice, store` for a richer blast-radius graph. |
| Deployment split | **Workload + MCP local (Compose); telemetry to SaaS** | Correlation across real backends is the point; SaaS trials avoid heavy local backends. |
| MCP scope | **Lookup + correlation + scoped runbooks** | No raw infra control — remediation is bounded to vetted runbooks. |
| Remediation safety | **Code-enforced propose-before-act gate (Phase 4 §4.9)** | `run_runbook` is intercepted before it ever reaches the proxy; only a separate `"approve <token>"` chat message can trigger real execution — not just a prompt instruction a model could ignore. |
| Agent framework | **Ballerina (native HTTP + tool-use loop)** | Anthropic Messages API called directly; tool dispatch implemented in `code/agent/`; no SDK dependency. |
| MCP transport | **Streamable HTTP (`:8290`)** | stdio does not work in K8s; the agent pod needs a network endpoint. |
| Service catalog | **Static in-code map (`catalog.bal`)** | Simple for a POC; production would read a real CMDB. |
| Log/metric routing | **Logs→Splunk, metrics→Datadog, traces→both** | Each backend owns its signal of record; traces dual-shipped to enable correlation. |

---

## 10. Known gotchas & risks

| Gotcha | Impact | Mitigation |
|--------|--------|------------|
| **Trace-ID format mismatch** (Datadog 64-bit vs OTel 128-bit) | Agent says "no logs found" because it searches Splunk with the wrong-width ID | `correlate_trace` must normalize/handle both `dd.trace_id` and `otel.trace_id`; confirm the real format during the Phase 1 smoke test |
| **NATS async trace propagation** | `order → notification` shows as a disconnected trace | Explicitly inject W3C trace-context into the NATS envelope; build it in from day one |
| **SSE buffering through the MCP Gateway** | Streaming `run_runbook` output breaks (no intermediate progress) | Verify the API Manager MCP Gateway does **not** buffer SSE; test early |
| **Pod → Compose reachability** | Agent pod in k3d can't reach MCP / mesh in Compose via Compose service names | Use `host.k3d.internal:<port>` — set via `SPLUNK_MCP_URL`, `DATADOG_MCP_URL`, `BALLERINA_TOPOLOGY_MCP_URL` env vars in the AMP component config |
| **Untraced Postgres queries** | DB latency invisible; can't diagnose slow-query regression | Enable the Ballerina SQL connector's tracing flag → DB calls become child spans |
| **Shared Postgres cross-talk** | A chaos slow query in one service muddies another | Schema/DB per service via `compose/postgres/init.sql` |
| **Ballerina OTel exporter version drift** | "unknown field" warnings in Collector logs | Pin a compatible OTel SDK version |
| **Splunk HEC token scope** | Trial token may not create new indexes | Send to `main` unless an index is pre-created |
| **Runbook idempotency** | Double-invoking `restart-service` mid-run | Per-runbook lock |
| **Token leakage in agent traces** | Bearer tokens captured in request bodies | Use Agent Manager's redaction config |
| **Clock skew / ingest lag** | Containers vs SaaS timing drift during smoke tests | Watch ingest delays; narrate over lag in the live demo |
| **Context saturation when real vendor MCPs are wired in** | Official Splunk + Datadog MCPs expose 50+ tools each | Handled by design: the proxy federates the backends and keeps their manifests in a server-side registry, revealing them only via `discover_tools` (lazy loading). Swapping to live MCPs is a `SPLUNK_MCP_URL`/`DATADOG_MCP_URL` change on the proxy — no agent change |

---

## 11. Repository layout

`DevOpsOverSightAgent/` is the GitHub push root. Directories are created as their phase reaches it; the table
below shows the intended final layout and the phase that builds each.

```
DevOpsOverSightAgent/
├── CLAUDE.md            project instructions for Claude Code
├── README.md            component catalog + getting-started
├── Makefile             convenience targets: demo-mock-up, test-bal, test-proxy, investigate, …
├── architecture/        deep-dive architecture docs (this directory)
│   ├── architecture.md          this document
│   ├── sequence-overview.md     agent → proxy → backends flow diagram
│   └── sequence-tool-routing.md registry lookup + prefix routing inside the proxy
├── code/                ALL Ballerina source
│   ├── agent/           DevOps OverSight agent (LLM tool-use loop) [Phase 4]
│   │   └── tests/       pure-function unit tests (no network)
│   ├── mcp/             MCP servers
│   │   ├── mcp-proxy/   MCP Proxy (Streamable HTTP :8290) [Phase 3]
│   │   │   └── runbooks/ restart-service, clear-cache, disable-chaos, freeze-deploys
│   │   ├── splunk-mock-mcp/ mock Splunk MCP backend (:8400) [Phase 4]
│   │   └── datadog-mock-mcp/ mock Datadog MCP backend (:8401) [Phase 4]
│   └── generate/        mesh services + load-gen
│       ├── store/ customer/ order/ inventory/
│       ├── invoice/ payment/ notification/
│       └── load-gen/
├── compose/       MCP Proxy (Streamable HTTP :8290) [Phase 3]
│   │   └── runbooks/    runbook fns: restart-service, clear-cache, disable-chaos, freeze-deploys
│   ├── splunk-mock-mcp/ mock Splunk MCP backend (:8400)  [Phase 4]
│   ├── datadog-mock-mcp/ mock Datadog MCP backend (:8401) [Phase 4]
│   └── agent/           Ballerina DevOps agent (LLM tool-use loop) [Phase 4]
│       └── tests/       pure-function unit tests (no network)
├── compose/             Docker Compose stack
│   ├── docker-compose.yml      all services: mesh, mcp-proxy, mock MCPs, agent, infra
│   ├── .env.example            committed; .env is gitignored
│   ├── otel-collector/config.yaml   OTLP receivers + splunk_hec + datadog exporters
│   └── postgres/init.sql       schema/DB per service
├── tests/               test scripts
│   ├── runUnitTests.sh          run bal test across all 12 packages (starts infra via compose)
│   ├── runDockerConfigTests.sh  creds-free integration test: proxy federation + routing
│   ├── ralph-tests.sh           iterative Claude Code fix loop for unit test failures
│   └── README.md                per-service unit test inventory
├── demo/                demo orchestration (Phase 5)
│   ├── script.md               verbatim narration + commands
│   ├── inject-chaos.sh         starts the headline scenario (payment-service)
│   └── reset.sh                /chaos/reset across all seven services
└── todo/                authoritative phase specs (phase-0 … phase-5)
```

| Directory | Role | Built in |
|-----------|------|----------|
| `architecture/` | Deep-dive architecture docs + sequence diagrams | Phase 0+ |
| `code/` | All Ballerina source: `agent/` (DevOps agent), `mcp/` (MCP Proxy + 2 mock MCPs), `generate/` (7 mesh services + load-gen) | Phases 2–4 |
| `compose/` | Docker Compose stack, OTel Collector config, Postgres init, env templates | Phase 1 (+2/3/4) |
| `tests/` | Unit test runner, Docker integration test, Claude Code fix loop | Phases 2–4 |
| `demo/` | Demo script, chaos-inject and reset scripts, recovery procedures | Phase 5 |
| `todo/` | Phase specs — the authoritative implementation source of truth | reference |

---

## 12. Single-agent + MCP Proxy vs. agent-to-agent (A2A)

**Decision:** one reasoning agent behind a single MCP Proxy that federates the backends — **not** a
multi-agent / agent-to-agent topology. This section records *why*, because "why isn't this
multi-agent?" is a question the design will be asked repeatedly.

### The two topologies

| | **Single-agent + proxy (chosen)** | **Agent-to-agent (A2A)** |
|---|---|---|
| Shape | One LLM loop; one MCP client; a proxy fans out to Splunk-MCP / Datadog-MCP / remediation-MCP | An orchestrator agent delegates to specialist agents (Splunk agent, Datadog agent, remediation agent), each its own LLM loop, coordinating over an agent protocol |
| Splunk & Datadog signals | Live in **one reasoning context** | Live in **separate contexts**, serialized across an agent boundary |
| Tools vs. peers | Backends are **tools** | Backends are **peers** |

### Why the proxy wins *for this system*

The differentiator here is **correlation** — joining a Splunk log line to a Datadog span to a
topology edge. Correlation is a **convergent, single-context reasoning task**: the model must hold
the log evidence and the metric evidence in the same working set to notice they share a `trace_id`
at the same instant. Splitting Splunk and Datadog into separate agents puts that evidence in two
contexts and forces each specialist to **summarize its findings into text** before the orchestrator
can correlate — a lossy compression step inserted at exactly the wrong place. A2A would fragment the
very thing the system exists to demonstrate.

Two secondary costs reinforce the choice:

- **Non-determinism compounds.** N agent loops = N× the places a run can wander. The existing
  `maxTurns` sensitivity (§ agent config) becomes a cross-agent coordination-turns problem.
- **Cost and latency multiply** by the agent count, and every handoff is another round trip — the
  enemy of a repeatable 5-minute demo.

The tell: **A2A pays off when work decomposes cleanly; this work converges** (many signals → one
verdict). Convergent problems want one context.

### Where A2A *would* be right

Not never — just not here. A2A earns its complexity at **organizational boundaries** (different
teams own and independently govern the Splunk vs. Datadog vs. remediation surfaces), under
**tool-count explosion** (a single agent's tool list is hundreds of tools and selection degrades —
this POC has ~11 topology tools + lazy-loaded backend tools), or when sub-problems are **genuinely
independent** (parallel decomposition where sub-agents don't need each other's raw evidence). Those
are enterprise-scale concerns — see §13.

### The nuance: trust boundary ≠ reasoning boundary

Note that Phase 3's [refactor R3.2](../todo/phase-3-mcp.md) splits *remediation* into its own gated
MCP server. That is the **correct** kind of separation — a **trust boundary** isolating dangerous
write actions behind their own auditable surface — while keeping all **diagnosis reasoning in one
agent context**. It delivers the isolation/governance benefit people reach for A2A to get, without
paying the correlation-fragmentation cost.

### Migration path is clean

Because everything is already MCP, outgrowing the POC into an org-boundary A2A design costs nothing
in rework: a "Splunk agent" is just today's Splunk-MCP with a reasoning loop bolted on, and
mainstream A2A protocols are largely MCP-shaped. Start with the proxy; earn the complexity later.

---

## 13. Production architecture (enterprise — "ACME")

The POC is deliberately single-node and creds-light. This section sketches how the same design
scales to a large regulated enterprise ("ACME"). The **core shape is preserved** — MCP is still the
contract boundary, correlation still happens in one context, remediation is still a gated trust
domain — but four things change decisively: **identity/governance become mandatory**, the
**catalog becomes system-of-record-backed**, **remediation goes through change management**, and
**A2A appears — but only at the org boundary**, wrapping the still-single correlation core.

```
┌────────────────────────────────────────────────────────────────────────────────────┐
│  IDENTITY & GOVERNANCE PLANE                                                          │
│  OIDC/SSO (e.g. Okta) · Vault/secrets-mgr · WSO2 Agent Manager (policy · quota ·      │
│  audit · agent OTel) · model routing + fallback · PII/token redaction · eval harness  │
└───────────────────────────────────┬────────────────────────────────────────────────┘
                                     │ authenticates · governs · observes
┌───────────────────────────────────▼────────────────────────────────────────────────┐
│  AGENT PLANE   (Kubernetes · multi-AZ · autoscaled)                                   │
│                                                                                       │
│   Orchestrator / triage agent   ◄──── incident intake (event bus, below)              │
│      │   keeps CORRELATION in ONE context (the POC core, unchanged)                   │
│      │   delegates only domain-bounded, cleanly-separable work via A2A ──┐            │
│      ├─ Splunk domain agent        (owned by the logging platform team)  │            │
│      ├─ Datadog/APM domain agent   (owned by the observability team)     │ org        │
│      └─ Change/remediation agent   (owned by SRE / platform ops)         │ boundary   │
└───────────────────────────────────┬───────────────────────────────────────────────┘
                                     │ EVERY tool call traverses ▼
┌───────────────────────────────────▼────────────────────────────────────────────────┐
│  MCP GATEWAY   (WSO2 API Manager) — mandatory single chokepoint                       │
│  per-tool authN/Z · RBAC · rate-limit · quota · full audit trail · schema governance  │
└───┬──────────────┬───────────────┬────────────────┬────────────────┬────────────────┘
    │ READ         │ READ          │ READ           │ READ           │ WRITE (gated)
┌───▼─────┐  ┌─────▼──────┐  ┌─────▼──────┐  ┌───────▼───────┐  ┌─────▼──────────────────┐
│ Splunk  │  │  Datadog   │  │  CMDB /    │  │  Topology /   │  │  Remediation MCP        │
│  MCP    │  │  MCP       │  │  ITSM MCP  │  │  correlation  │  │  (own trust domain)     │
│(official│  │ (official) │  │(ServiceNow,│  │  MCP          │  │  GitOps/Argo · K8s API ·│
│ SaaS)   │  │            │  │  CMDB)     │  │ (catalog from │  │  feature flags · change │
└───┬─────┘  └─────┬──────┘  └─────┬──────┘  │  CMDB, not     │  │  tickets · runbooks     │
    │              │               │         │  static map)  │  └─────┬───────────────────┘
┌───▼──────────────▼───────────────▼─────────┴───────────────┐        │ actuates ONLY after
│  ENTERPRISE SYSTEMS OF RECORD                               │        │ policy + human approval
│  Splunk Enterprise/Cloud · Datadog org · CMDB · ITSM · Git  │        ▼
└──────────────────────────────▲──────────────────────────────┘   Production workloads
                               │ telemetry (OTel gateway + agent tiers)   (fleet · multi-region)
                               └───────────────────────────────────────────────┘

Intake & human-in-the-loop:  Datadog/Splunk alerts ─► event bus (Kafka) ─► orchestrator
                             approvals & narration ─► ChatOps (Slack/Teams) + ITSM (ServiceNow)
```

### What changes from POC → production

| Dimension | POC (today) | Production (ACME) |
|-----------|-------------|-------------------|
| **Service catalog** | Static in-code map (`catalog.bal`) | Live **CMDB / ServiceNow** behind a catalog MCP; topology discovered, not hardcoded |
| **Identity & secrets** | Bearer tokens in env vars | **OIDC/SSO** for humans, workload identity for agents; secrets in **Vault**; no long-lived tokens |
| **MCP Gateway** | Optional | **Mandatory** single chokepoint — per-tool RBAC, rate-limit, quota, full audit, schema governance |
| **Remediation trust** | Propose-before-act gate; local runbooks | Separate remediation MCP in its **own trust domain**; actions flow through **GitOps/change tickets**; approval via ChatOps + ITSM with full change-management trail |
| **Agent topology** | Single agent + proxy | Single correlation core **wrapped by** org-boundary A2A: domain agents owned by the teams that own each platform (the §12 "when A2A is right" case) |
| **Intake** | Datadog webhook / CLI | Alert **event bus (Kafka)**; dedup, throttle, correlate multiple alerts into one incident |
| **LLM** | `LLM_PROVIDER` env switch | **Model router** with fallback, cost controls, per-domain model choice; private/self-hosted models for sensitive data |
| **HA / scale** | Single node | Multi-AZ Kubernetes, autoscaled agents, back-pressure on the gateway |
| **Data governance** | Token scrubbing noted | Enforced **PII/secret redaction** before any signal reaches an LLM or trace store; data-residency-aware MCP routing |
| **Quality** | Unit tests | **Eval + regression harness** on the typed diagnosis contract (§Phase 4) — accuracy gates before promotion |
| **Audit & compliance** | In-memory audit log | Immutable, exportable audit of every tool call + every remediation, tied to SSO identity for SOX/regulatory review |

### What stays the same (the durable bets)

- **MCP is the contract boundary** — every capability is a tool; vendor swaps are config, not code.
- **Correlation lives in one reasoning context** — even with A2A at the org boundary, the join is not
  fragmented across agents (§12).
- **Read/write are different trust tiers**, with remediation physically isolated behind its own gated
  MCP (Phase 3 R3.1/R3.2).
- **The typed diagnosis contract** (Phase 4) is what makes the enterprise eval, audit, and
  approval-routing stories possible — structure over prose is load-bearing at scale.

The through-line: **the POC is a faithful vertical slice of the production design, not a throwaway.**
Everything added in production is a governance, scale, or systems-of-record concern layered *around*
an unchanged core.

---

## 14. References

- [`CLAUDE.md`](CLAUDE.md) — locked decisions, architecture summary, data flows, known gotchas
- [`README.md`](README.md) — component catalog + getting-started
- [`todo/README.md`](todo/README.md) — overall phased plan + architecture-at-a-glance
- [`todo/phase-0-prereqs.md`](todo/phase-0-prereqs.md) — prerequisites & locked decisions
- [`todo/phase-1-compose.md`](todo/phase-1-compose.md) — Docker Compose observability stack
- [`todo/phase-2-ballerina.md`](todo/phase-2-ballerina.md) — the 7-service mesh + load-gen + topology
- [`todo/phase-3-mcp.md`](todo/phase-3-mcp.md) — MCP Proxy, tools, runbooks
- [`todo/phase-4-agent.md`](todo/phase-4-agent.md) — Ballerina agent + MCP Proxy wiring under Agent Manager
- [`todo/phase-5-verify.md`](todo/phase-5-verify.md) — headline incident-triage demo + rehearsal
