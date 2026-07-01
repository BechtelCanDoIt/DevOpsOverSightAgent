# Architecture — DevOps Observability POC

This POC demonstrates an AI agent that diagnoses and remediates a production-style incident by
correlating signals across **two real observability backends**. A Ballerina retail microservice
mesh emits traces, logs, and metrics through a **single OpenTelemetry Collector** that fans out to
**Splunk** (logs/traces) and **Datadog** (APM/metrics). A **Ballerina agent** calls a configurable
LLM via HTTP using a native tool-use loop — **local Ollama** (creds-free, default), **Anthropic
Claude**, **OpenAI**, or **WSO2 AMP** (switched via `LLM_PROVIDER` env var) — and reaches all
observability signal sources through a single **MCP Proxy** (`:8290`). The proxy owns the service
catalog, cross-system trace correlation, and scoped remediation runbooks locally, and routes
Splunk and Datadog tool calls to their respective backends (mock MCPs by default; swapped for
official SaaS MCPs when creds arrive). The headline scenario: an operator injects chaos into
`payment-service`, a Datadog monitor fires, and the agent investigates end-to-end, proposes a
runbook, and — after human approval — remediates and writes a postmortem.

> This document is the deep-dive architecture reference. For component-by-component descriptions and
> getting-started instructions, see the root [`README.md`](README.md). The authoritative
> implementation specs are the phase docs under [`todo/`](todo/) (see [References](#12-references)).

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
│   │     src: generate/agent/                                                      │   │
│   │     OTel: ballerinax/jaeger (OTLP gRPC) + ballerinax/prometheus              │   │
│   │     LLM: Ollama (default, creds-free) | Anthropic | OpenAI | AMP             │   │
│   │     └── single MCP client ──► MCP Proxy (:8290)                              │   │
│   │  (mcp_client.bal)              src: generate/mcp-proxy/                     │   │
│   └──────────────────────────────────────────────────────────────────────────────┘   │
│                      │ (optional) WSO2 API Manager MCP Gateway: auth, rate-limit, audit│
└──────────────────────┼─────────────────────────────────────────────────────────────────┘
                       │  reached via host.k3d.internal:8290
┌──────────────────────┼─────────────────────────────────────────────────────────────────┐
│  DOCKER COMPOSE  (bridge network: devops-poc)  —  Workload + observability tier        │
│                       ▼                                                                 │
│   MCP Proxy (Streamable HTTP, :8290)   src: generate/mcp-proxy/                       │
│   ├── topology/correlation/runbook tools  (local, owns service catalog)                │
│   ├── routes Splunk calls  ──► splunk-mock-mcp (:8400)  [or real Splunk MCP via env]   │
│   └── routes Datadog calls ──► datadog-mock-mcp (:8401) [or real Datadog MCP via env]  │
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

**How the tiers connect.** The agent runs in k3d (via the AMP quick-start container); the MCP Proxy, mock MCP backends, and workload run in Compose on the host. The agent pod reaches the proxy via `host.k3d.internal:8290` — a hostname k3d registers in every pod that resolves to the Docker host. MCP port `8290` is published to the host in `docker-compose.yml`. To swap in real SaaS MCPs, set `SPLUNK_MCP_URL` and `DATADOG_MCP_URL` on the proxy — no agent code changes required.

---

## 3. Workload service mesh

A realistic retail mesh — the whole point is **cross-service correlation, blast-radius, and
"which downstream caused this."** Each source directory `generate/<x>/` maps to service name
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

`generate/load-gen/` is a long-lived Ballerina worker (not a service). It reads a YAML pattern file
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

The agent is **Ballerina** (same as the workload mesh and MCP Proxy — the entire stack is Ballerina). It calls the LLM directly via HTTP using a native tool-use loop; no SDK required. The LLM backend is selected by the `LLM_PROVIDER` env var: `ollama` (default, creds-free, local Ollama at `OLLAMA_BASE_URL`), `anthropic` (Anthropic Messages API; AMP proxy via `ANTHROPIC_URL`), `openai`, or `amp` (WSO2 AMP AI gateway). OTel instrumentation uses the same `ballerinax/jaeger` + `ballerinax/prometheus` pattern as the mesh services.

### MCP Proxy and backends

The agent connects to a **single MCP Proxy** (`:8290`). The proxy owns the service catalog tools locally and routes Splunk/Datadog tool calls to the configured backends. Swapping from mock to real SaaS MCPs requires only an env-var change on the proxy.

| Component | Origin | Hosting / transport | Key tools | Config |
|-----------|--------|---------------------|-----------|--------|
| **MCP Proxy** | Custom (this repo) | **Host-local** in Compose, Streamable HTTP `:8290` | topology / correlation / runbooks (catalog below) + proxied Splunk/Datadog tools | `generate/mcp-proxy/`; client `generate/agent/mcp_client.bal` |
| **Splunk MCP** | Official — *MCP Server for Splunk platform* (Splunkbase 7931) | App on **your Splunk Cloud**; Streamable HTTP; MCP bearer token (RBAC `mcp_tool_execute`). Default: `splunk-mock-mcp :8400` | `splunk_run_query` (SPL), `splunk_get_indexes`, `splunk_get_knowledge_objects` | env `SPLUNK_MCP_URL` on the proxy |
| **Datadog MCP** | Official — *Datadog MCP Server* (Bits AI) | **Remote-hosted** `mcp.datadoghq.com` (regional per `DD_SITE`). Default: `datadog-mock-mcp :8401` | `get_datadog_metric`, `search_datadog_error_tracking_issues`, `get_datadog_trace`, `search_datadog_logs`, `search_datadog_monitors` | env `DATADOG_MCP_URL` on the proxy |

Splunk MCP knows logs; Datadog MCP knows metrics and traces. **Neither knows your service catalog,
dependency graph, owners, or runbooks** — the MCP Proxy fills that gap with local tools, and
because it is Ballerina it can also *act* (hit chaos endpoints, restart containers) to remediate.

### MCP Proxy tool catalog

`tools/list` returns **only `discover_tools` plus the 11 `topology__*` tools** — Splunk/Datadog tool schemas are hidden in the server-side registry until the agent calls `discover_tools(query)`. Tool names below are exactly as the agent sees and calls them.

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
| **Runbooks** | `topology__list_runbooks` | (none) | Array of `{ id, name, description, params_schema }` |
| | `topology__run_runbook` | `id`, `params` | **SSE-streaming** progress of runbook execution |
| **Ops** | `topology__get_audit_log` | (none) | Recent runbook execution audit entries |
| | `topology__get_deploy_freeze_status` | (none) | Current deploy-freeze flag state |

**Initial runbooks** (live as Ballerina functions in `mcp-proxy/runbooks/*.bal`, each appending to an
`audit.log`):

| Runbook | Action |
|---------|--------|
| `restart-service` | Restart a container/pod via Docker/K8s API (per-runbook lock for idempotency) |
| `clear-cache` | Redis `FLUSHDB` on `inventory-service`'s cache |
| `disable-chaos` | Calls `/chaos/reset` on a target service — **most-used in the demo** |
| `freeze-deploys` | Sets a flag in the stub deploy registry |

The service catalog is a static YAML committed to the repo (`catalog/services.yaml`) enumerating all
seven mesh services with `dependencies` matching the §3 topology; production would discover from a
real CMDB.

### Tool-loading approach and scaling note

The agent starts each `investigate()` / `chat()` call with only the `discover_tools(query)` tool in context — **lazy tool loading (Pattern 2 from the MCP scaling guide)**. The agent calls `discover_tools` with a natural-language description of what it needs; the proxy scores all registered tool manifests (across the topology, Splunk, and Datadog namespaces) and returns the top-k matches, which are injected for that turn only. This keeps the initial context window small regardless of how many tools the real Splunk and Datadog MCPs expose.

The tool registry is backed by a keyword-based scorer today; a pgvector + `nomic-embed-text` upgrade (already in the stack) is the planned improvement for production-grade routing accuracy. This work is tracked in the Phase 4 exit criteria.

### Optional API Manager MCP Gateway

The **MCP Proxy** (the agent's single entry point) may be fronted by the **WSO2 API Manager MCP Gateway**, which gives **auth, rate-limiting, and audit "for free."** The agent's single `BALLERINA_TOPOLOGY_MCP_URL` points at the gateway URL; the gateway forwards to the proxy, which continues to federate the Splunk/Datadog backends as normal.

### Agent self-observability (the meta-win)

The agent watching the workload is itself watched. After triggering an investigation, `amp-console` /
`amp-trace-observer` shows the full agent trace with each **tool call as a span**, plus per-LLM-call
latency and token usage. Caveat: `amp-instrumentation` may capture request bodies — bearer tokens must
be scrubbed via Agent Manager's redaction config before they hit the trace observer.

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
| 4 | **Propose / approve** | Agent calls `topology__list_runbooks`, **proposes** `disable-chaos` (does not run it); human approves in the agent console. |
| 5 | **Remediate** | Agent calls `topology__run_runbook("disable-chaos", { service: "payment-service" })`; SSE streams progress; chaos resets; mesh recovers. |
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
| LLM | **Configurable via `LLM_PROVIDER`** | `ollama` (default, creds-free), `anthropic`, `openai`, `amp`. All four providers implemented in `generate/agent/llm_client.bal`; no SDK dependency — calls the provider's HTTP API directly. |
| Local Kubernetes | **k3d** (via AMP quick-start) | AMP quick-start bootstraps its own k3d cluster (`amp-local`); no separate kind setup needed. |
| Splunk deployment | **Splunk Cloud trial** | Splunk Enterprise in a container is heavy and unrealistic; trial reached via the Collector's `splunk_hec` exporter. |
| Telemetry shipper | **Single OTel Collector** | One unified fan-out point instead of separate per-vendor agents. |
| Agent language | **Ballerina** | Full-stack Ballerina — overrides the Phase 0 Python decision. Ballerina OTel (`ballerinax/jaeger` + `ballerinax/prometheus`) covers the observability need; the tool-use loop calls Anthropic directly via HTTP. |
| Workload + MCP language | **Ballerina** | Showcases Ballerina's integration story for the mesh and the MCP Proxy. |
| Mesh shape | **Hybrid (7 services)** | Kept the 4 spec services (`order, payment, inventory, notification`) and added `customer, invoice, store` for a richer blast-radius graph. |
| Deployment split | **Workload + MCP local (Compose); telemetry to SaaS** | Correlation across real backends is the point; SaaS trials avoid heavy local backends. |
| MCP scope | **Lookup + correlation + scoped runbooks** | No raw infra control — remediation is bounded to vetted runbooks. |
| Remediation safety | **Propose-before-act gate** | Agent must `list_runbooks` and present its choice; a human approves before `run_runbook`. |
| Agent framework | **Ballerina (native HTTP + tool-use loop)** | Anthropic Messages API called directly; tool dispatch implemented in `generate/agent/`; no SDK dependency. |
| MCP transport | **Streamable HTTP (`:8290`)** | stdio does not work in K8s; the agent pod needs a network endpoint. |
| Service catalog | **Static `catalog/services.yaml`** | Simple for a POC; production would read a real CMDB. |
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
├── generate/            ALL Ballerina source — one package per dir
│   ├── store/           store-service        ┐
│   ├── customer/        customer-service     │
│   ├── order/           order-service        │ 7-service mesh
│   ├── inventory/       inventory-service    │ (dir <x>/ → <x>-service)
│   ├── invoice/         invoice-service      │
│   ├── payment/         payment-service      │  (headline chaos target)
│   ├── notification/    notification-service ┘
│   ├── load-gen/        traffic generator + chaos one-liners
│   ├── mcp-proxy/       MCP Proxy (Streamable HTTP :8290) [Phase 3]
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
├── catalog/             services.yaml — static service catalog (Phase 3)
├── demo/                demo orchestration (Phase 5)
│   ├── script.md               verbatim narration + commands
│   ├── inject-chaos.sh         starts the headline scenario (payment-service)
│   └── reset.sh                /chaos/reset across all seven services
└── todo/                authoritative phase specs (phase-0 … phase-5)
```

| Directory | Role | Built in |
|-----------|------|----------|
| `architecture/` | Deep-dive architecture docs + sequence diagrams | Phase 0+ |
| `generate/` | All Ballerina source: 7-service mesh, `load-gen`, MCP Proxy, mock MCPs, Ballerina agent | Phases 2–4 |
| `compose/` | Docker Compose stack, OTel Collector config, Postgres init, env templates | Phase 1 (+2/3/4) |
| `tests/` | Unit test runner, Docker integration test, Claude Code fix loop | Phases 2–4 |
| `catalog/` | `services.yaml` — service catalog backing the MCP Proxy topology tools | Phase 3 |
| `demo/` | Demo script, chaos-inject and reset scripts, recovery procedures | Phase 5 |
| `todo/` | Phase specs — the authoritative implementation source of truth | reference |

---

## 12. References

- [`CLAUDE.md`](CLAUDE.md) — locked decisions, architecture summary, data flows, known gotchas
- [`README.md`](README.md) — component catalog + getting-started
- [`todo/README.md`](todo/README.md) — overall phased plan + architecture-at-a-glance
- [`todo/phase-0-prereqs.md`](todo/phase-0-prereqs.md) — prerequisites & locked decisions
- [`todo/phase-1-compose.md`](todo/phase-1-compose.md) — Docker Compose observability stack
- [`todo/phase-2-ballerina.md`](todo/phase-2-ballerina.md) — the 7-service mesh + load-gen + topology
- [`todo/phase-3-mcp.md`](todo/phase-3-mcp.md) — MCP Proxy, tools, runbooks
- [`todo/phase-4-agent.md`](todo/phase-4-agent.md) — Ballerina agent + MCP Proxy wiring under Agent Manager
- [`todo/phase-5-verify.md`](todo/phase-5-verify.md) — headline incident-triage demo + rehearsal
