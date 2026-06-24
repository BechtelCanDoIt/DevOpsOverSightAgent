# Architecture — DevOps Observability POC

This POC demonstrates an AI agent that diagnoses and remediates a production-style incident by
correlating signals across **two real observability backends**. A Ballerina retail microservice
mesh emits traces, logs, and metrics through a **single OpenTelemetry Collector** that fans out to
**Splunk** (logs/traces) and **Datadog** (APM/metrics). A **Ballerina agent** calls **Anthropic
Claude** directly via HTTP and reaches all three signal sources over **MCP** (Model Context
Protocol) — Splunk mock MCP, Datadog mock MCP (swapped for official MCPs when SaaS creds arrive),
and a **custom Ballerina MCP** that owns the service catalog, cross-system trace correlation, and
scoped remediation runbooks. The headline scenario: an operator injects chaos into
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
| **Workload + observability** | Docker Compose (bridge network `devops-poc`) | 7-service Ballerina mesh, `load-gen`, OTel Collector, Datadog Agent, NATS, Postgres, Redis, (optional Jaeger), Ballerina MCP server, mock MCP servers | Phases 1–3 |
| **Agent** | Docker Compose (same stack) or Kubernetes (kind, optional) | Ballerina agent (OTel-instrumented), calling Anthropic Claude; mock Splunk/Datadog MCPs until SaaS creds arrive | Phase 4 |

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
│   │  Python agent  (Claude Agent SDK, Anthropic Claude)   src: agent/                   │   │
│   │     ▲  init container: amp-python-instrumentation-provider                     │   │
│   │     │  injects amp-instrumentation (OTel) → traces in amp-trace-observer       │   │
│   │     │                                                                          │   │
│   │     └── MCP client ──┬── Splunk MCP   (official; logs)        agent/splunk/mcp/ │   │
│   │                      ├── Datadog MCP  (official; metrics+APM) agent/datadog/mcp/│   │
│   │                      └── Ballerina MCP (custom; topology /                     │   │
│   │                            correlation / runbooks)  client wiring: agent/mcp/  │   │
│   └──────────────────────────────────────────────────────────────────────────────┘   │
│                      │ (optional) WSO2 API Manager MCP Gateway: auth, rate-limit, audit│
└──────────────────────┼─────────────────────────────────────────────────────────────────┘
                       │
       host bridge:  host.docker.internal  (Docker Desktop)  /  NodePort (kind)
                       │
┌──────────────────────┼─────────────────────────────────────────────────────────────────┐
│  DOCKER COMPOSE  (bridge network: devops-poc)  —  Workload + observability tier        │
│                       ▼                                                                 │
│   Ballerina MCP server (Streamable HTTP, :8290)   src: generate/mcp-server/            │
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

**How the tiers connect.** The agent runs in K8s; the MCP servers and workload run in Compose on the
host. The agent pod reaches the Compose endpoints via `host.docker.internal` (Docker Desktop) or a
NodePort / host IP (kind). The Splunk MCP and Datadog MCP talk to the SaaS backends directly over the
internet; only the **Ballerina MCP** (`:8290`) is a host-local endpoint the agent must route to.

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
| `GET /health` | Liveness + quick check; probed by the Ballerina MCP `get_service_health(name)` tool |
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

The agent is **Python** (not Ballerina) because WSO2 Agent Manager's auto-instrumentation is
Python-first: `amp-instrumentation` is a Python OTel auto-instrumentation package, and
`amp-python-instrumentation-provider` is the K8s init container that injects it — so the agent's own
reasoning, tool calls, latency, and token usage appear in `amp-trace-observer` with **zero code
changes**. Ballerina stays where it shines: the workload mesh and the MCP server.

### Three MCP servers

| MCP server | Origin | Hosting / transport / auth | Key tools | Config |
|------------|--------|----------------------------|-----------|--------|
| **Splunk MCP** | Official — *MCP Server for Splunk platform* (Splunkbase 7931) | App on **your Splunk Cloud**; Streamable HTTP; MCP bearer token (RBAC `mcp_tool_execute`) | `splunk_run_query` (SPL), `splunk_get_indexes`, `splunk_get_knowledge_objects` | `agent/splunk/mcp/` |
| **Datadog MCP** | Official — *Datadog MCP Server* (Bits AI) | **Remote-hosted** `mcp.datadoghq.com` (regional per `DD_SITE`; Preview, `/api/unstable/`); Streamable HTTP; OAuth or `DD_API_KEY`+`DD_APPLICATION_KEY` | `get_datadog_metric`, `search_datadog_error_tracking_issues`, `get_datadog_trace`, `search_datadog_logs`, `search_datadog_monitors` | `agent/datadog/mcp/` |
| **Ballerina MCP** | Custom (this repo) | **Host-local** in Compose, Streamable HTTP `:8290`, reached via `host.docker.internal` | topology / correlation / runbooks (catalog below) | server `generate/mcp-server/`; client `agent/mcp/` |

Splunk MCP knows logs; Datadog MCP knows metrics and traces. **Neither knows your service catalog,
dependency graph, owners, or runbooks** — the custom Ballerina MCP fills that gap, and because it is
Ballerina it can also *act* (hit chaos endpoints, restart containers) to remediate.

### Ballerina MCP tool catalog

| Group | Tool | Inputs | Returns |
|-------|------|--------|---------|
| **Lookup / topology** | `lookup_service` | `name` | `{ owner, repo, runbook_ids, sla, health_endpoint, dependencies }` |
| | `get_dependencies` | `name`, `direction` (`upstream`/`downstream`/`both`) | Adjacency list — must match the §3 topology exactly |
| | `list_services` | (none) | All known services + `last_seen` |
| | `get_service_health` | `name` | Probes `/health` live; returns status + latency |
| **Correlation** | `correlate_trace` | `trace_id` | Datadog APM URL + pre-filtered Splunk search URL + involved services + per-service log counts |
| | `find_recent_deploys` | `service`, `lookback` | Recent deploys (stub deploy log) — "did something change?" |
| | `find_related_incidents` | `service`, `lookback` | Past incidents (stub local SQLite) — learning-from-history |
| **Runbooks** | `list_runbooks` | (none) | Array of `{ id, name, description, params_schema }` |
| | `run_runbook` | `id`, `params` | **SSE-streaming** progress of runbook execution |

**Initial runbooks** (live as Ballerina functions in `mcp-server/runbooks/*.bal`, each appending to an
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

### Optional API Manager MCP Gateway

The three MCP servers may be fronted by the **WSO2 API Manager MCP Gateway**, which gives **auth,
rate-limiting, and audit "for free."** With the gateway, the agent points at *one* gateway URL with
three tool namespaces and defers auth to it; without it, the agent opens three direct MCP connections,
each with its own URL + bearer token. The gateway is the WSO2-native, cleaner-narrative option.

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
              Ballerina MCP: correlate_trace(trace_id)   ← links + topology only
                                          │
        ┌─────────────────────────────────┼─────────────────────────────────┐
        ▼                                 ▼                                   ▼
 Datadog APM deep-link          Splunk search URL / SPL           involved services
 app.{dd_site}/apm/             index=* trace_id={id}             (from static catalog)
   trace/{trace_id}             (pre-filled)                              │
        ▼                                 ▼                                  │
  Datadog MCP:                    Splunk MCP:                               │
  get_datadog_trace            splunk_run_query(SPL)  ◄── agent FETCHES the data ──┘
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
Operator        payment-svc      Datadog        Agent (Python)              Ballerina MCP / Splunk      Human
   │                 │              │                 │                            │                      │
 1.│ inject chaos ──►│              │                 │                            │                      │
   │ (30% 502 + 2s)  │ degrades     │                 │                            │                      │
 2.│                 │ ───metrics──►│ monitor fires    │                            │                      │
   │                 │              │ ──webhook (≤60s)►│                            │                      │
 3.│                 │              │   get_datadog_metric → error-rate spike       │                      │
   │                 │              │     └─ identifies payment-service as origin   │                      │
   │                 │              │   get_dependencies("payment-service",         │                      │
   │                 │              │       "downstream")  ─────────────────────────► blast radius         │
   │                 │              │   pull sample trace from Datadog              │                      │
   │                 │              │   correlate_trace(trace_id) ──────────────────► Datadog + Splunk URLs│
   │                 │              │     └─ Splunk logs show mock-bank timeouts ◄───┤                      │
   │                 │              │   find_recent_deploys("payment-service") ─────► nothing → rules out  │
   │                 │              │     └─ suspects chaos / external dependency   │   a deploy            │
 ──┼─────────────────┼──────────────┼── PROPOSE-BEFORE-ACT GATE ────────────────────┼──────────────────────┼──
   │                 │              │   proposes disable-chaos runbook ─────────────┼─────────────────────►│
 4.│                 │              │                 │                ◄── approves ─┼──────────────────────┤
 5.│                 │              │   run_runbook("disable-chaos",                │                      │
   │                 │◄─/chaos/reset─┤      {service:"payment-service"}) ──SSE──────► streams progress      │
   │                 │ recovers     │                 │                            │                      │
 6.│                 │              │   writes markdown postmortem (slide-ready)    │                      │
```

| Step | Beat | What happens |
|:----:|------|--------------|
| 1 | **Inject** | Operator triggers `payment-service` chaos: 30% 502 rate + 2s latency. Mesh degrades. |
| 2 | **Alert** | Pre-configured Datadog monitor fires within 60s; webhook hits the agent. |
| 3 | **Investigate** | Agent pulls metrics → identifies `payment-service` spike → `get_dependencies(...,"downstream")` for blast radius → pulls a sample trace → `correlate_trace` → jumps to Splunk logs showing **mock-bank timeouts** → `find_recent_deploys` finds nothing, rules out a deploy → suspects chaos/external dependency. |
| 4 | **Propose / approve** | Agent **proposes** `disable-chaos` (does not run it); human approves in the agent console. |
| 5 | **Remediate** | Agent calls `run_runbook("disable-chaos", { service: "payment-service" })`; SSE streams progress; chaos resets; mesh recovers. |
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
| LLM | **Anthropic Claude** | The Claude Agent SDK is Anthropic-native; supersedes the earlier Ollama pick. |
| Local Kubernetes | **kind** | Lightweight local cluster for the Agent Manager tier. |
| Splunk deployment | **Splunk Cloud trial** | Splunk Enterprise in a container is heavy and unrealistic; trial reached via the Collector's `splunk_hec` exporter. |
| Telemetry shipper | **Single OTel Collector** | One unified fan-out point instead of separate per-vendor agents. |
| Agent language | **Python** | WSO2 Agent Manager auto-instrumentation is Python-first (`amp-instrumentation`), so agent traces/tokens appear with zero code changes. |
| Workload + MCP language | **Ballerina** | Showcases Ballerina's integration story for the mesh and the custom MCP server. |
| Mesh shape | **Hybrid (7 services)** | Kept the 4 spec services (`order, payment, inventory, notification`) and added `customer, invoice, store` for a richer blast-radius graph. |
| Deployment split | **Workload + MCP local (Compose); telemetry to SaaS** | Correlation across real backends is the point; SaaS trials avoid heavy local backends. |
| MCP scope | **Lookup + correlation + scoped runbooks** | No raw infra control — remediation is bounded to vetted runbooks. |
| Remediation safety | **Propose-before-act gate** | Agent must `list_runbooks` and present its choice; a human approves before `run_runbook`. |
| Agent framework | **Claude Agent SDK (Python)** | Native MCP client + cleanest tool loop; first-class under Agent Manager's Python auto-instrumentation. |
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
| **Pod → Compose reachability** | Agent pod in K8s can't reach MCP / mesh in Compose | Reach via `host.docker.internal` (Docker Desktop) or NodePort / `extraHosts` in Helm values (kind) |
| **Untraced Postgres queries** | DB latency invisible; can't diagnose slow-query regression | Enable the Ballerina SQL connector's tracing flag → DB calls become child spans |
| **Shared Postgres cross-talk** | A chaos slow query in one service muddies another | Schema/DB per service via `compose/postgres/init.sql` |
| **Ballerina OTel exporter version drift** | "unknown field" warnings in Collector logs | Pin a compatible OTel SDK version |
| **Splunk HEC token scope** | Trial token may not create new indexes | Send to `main` unless an index is pre-created |
| **Runbook idempotency** | Double-invoking `restart-service` mid-run | Per-runbook lock |
| **Token leakage in agent traces** | Bearer tokens captured in request bodies | Use Agent Manager's redaction config |
| **Clock skew / ingest lag** | Containers vs SaaS timing drift during smoke tests | Watch ingest delays; narrate over lag in the live demo |

---

## 11. Repository layout

`DevOpsOverSightAgent/` is the GitHub push root. Directories are created as their phase reaches it; the table
below shows the intended final layout and the phase that builds each.

```
DevOpsOverSightAgent/
├── CLAUDE.md            project instructions for Claude Code
├── README.md            component catalog + getting-started
├── architecture.md      this document
├── generate/            ALL Ballerina source — one package per dir (Phases 2–3)
│   ├── store/           store-service        ┐
│   ├── customer/        customer-service     │
│   ├── order/           order-service        │ 7-service mesh
│   ├── inventory/       inventory-service    │ (dir <x>/ → <x>-service)
│   ├── invoice/         invoice-service      │
│   ├── payment/         payment-service      │  (headline chaos target)
│   ├── notification/    notification-service ┘  [to be created — Phase 2]
│   ├── load-gen/        traffic generator + chaos one-liners [to be created — Phase 2]
│   └── mcp-server/      custom Ballerina MCP (Streamable HTTP :8290) [Phase 3]
│       └── runbooks/    runbook fns: restart-service, clear-cache, disable-chaos, freeze-deploys
├── agent/               Python agent under WSO2 Agent Manager (Phase 4)
│   ├── (agent code, pyproject.toml, Dockerfile)
│   ├── splunk/mcp/      official Splunk MCP run/connection config
│   ├── datadog/mcp/     official Datadog MCP run/connection config
│   └── mcp/             client-side wiring to the custom Ballerina MCP
├── compose/             Docker Compose stack [to be created — Phase 1]
│   ├── docker-compose.yml      collector, datadog-agent, nats, postgres, redis,
│   │                           jaeger + (Phase 2) the 8 Ballerina + (Phase 3) mcp-server
│   ├── .env.example            committed; .env is gitignored
│   ├── otel-collector/config.yaml   OTLP receivers + splunk_hec + datadog exporters
│   └── postgres/init.sql       schema/DB per service
├── catalog/             services.yaml — static service catalog (Phase 3) [to be created]
├── demo/                demo orchestration (Phase 5) [to be created]
│   ├── script.md               verbatim narration + commands
│   ├── inject-chaos.sh         starts the headline scenario (payment-service)
│   └── reset.sh                /chaos/reset across all seven services
└── todo/                authoritative phase specs (phase-0 … phase-5)
```

| Directory | Role | Built in |
|-----------|------|----------|
| `generate/` | All Ballerina source: 7-service mesh, `load-gen`, custom MCP server | Phases 2–3 |
| `agent/` | Python agent + MCP client/connection config (Splunk, Datadog, Ballerina) | Phase 4 |
| `compose/` | Docker Compose stack, OTel Collector config, Postgres init, env templates | Phase 1 (+2/3) |
| `catalog/` | `services.yaml` — service catalog backing the Ballerina MCP topology tools | Phase 3 |
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
- [`todo/phase-3-mcp.md`](todo/phase-3-mcp.md) — custom Ballerina MCP server, tools, runbooks
- [`todo/phase-4-agent.md`](todo/phase-4-agent.md) — Python agent + MCP wiring under Agent Manager
- [`todo/phase-5-verify.md`](todo/phase-5-verify.md) — headline incident-triage demo + rehearsal
