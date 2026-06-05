# DevOps Observability POC

A local-first demo: a Ballerina retail microservice mesh emits traces, logs, and metrics through a single OTel Collector to **Splunk** (logs/traces) and **Datadog** (APM/metrics). A Python agent running under **WSO2 Agent Manager** correlates those signals over MCP to diagnose and remediate a chaos-induced incident.

## Repository layout

| Path | Contents |
|------|----------|
| [`README.md`](README.md) · [`architecture.md`](architecture.md) · [`CLAUDE.md`](CLAUDE.md) | This file (component reference); deep-dive architecture; Claude Code guidance + locked decisions |
| `todo/` | Authoritative phase specs (`phase-0` … `phase-5`) — start with [`todo/README.md`](todo/README.md) |
| `generate/` | Ballerina source — one package per service + `load-gen` + `mcp-server` |
| `agent/` | Python agent (Phase 4) and per-MCP connection config |
| `compose/` | Docker Compose observability stack (Phase 1) |
| `catalog/` | Service catalog YAML for the Ballerina MCP (Phase 3) |
| `demo/` | Demo script + chaos inject/reset scripts (Phase 5) |

## Service mesh (7 services + load-gen)

`store` · `customer` · `order` · `inventory` · `invoice` · `payment` · `notification`, driven by `load-gen`. See [`CLAUDE.md`](CLAUDE.md) for the architecture diagram and [`todo/phase-2-ballerina.md`](todo/phase-2-ballerina.md) for the mesh topology.

## Getting started

This POC is built phase-by-phase. See [`todo/README.md`](todo/README.md) for the phased plan and per-phase exit criteria.

---

## Architecture at a glance

The system has two tiers. A **workload tier** (Docker Compose) runs the seven-service Ballerina retail mesh plus the infrastructure it depends on (Postgres, Redis, NATS) and the telemetry pipeline (a single OTel Collector fanning out to Splunk and Datadog). 

An **agent tier** (Kubernetes/kind, under WSO2 Agent Manager) runs a Python incident-response agent that reaches three MCP servers — Splunk, Datadog, and the custom Ballerina MCP — to correlate signals and remediate.

For the deep dive — full topology diagrams, the telemetry fan-out, the trace-correlation flow, and the propose-before-act remediation loop — see **[`architecture.md`](architecture.md)**. This README is the component reference and getting-started; it does not duplicate those diagrams.

## Services

Every service is a Ballerina package under `generate/<dir>/`; its OTel service name is `<dir>-service`. Every service exposes its business routes plus `GET /health` (probed by the Ballerina MCP) and a token-gated, internal-only `POST /chaos/latency | /chaos/error | /chaos/reset` lever set used by the Phase 5 demo to inject and clear the incident.

| Service | Dir | Role | Talks to | Infra | Chaos modes |
|---|---|---|---|---|---|
| `store-service` | `generate/store/` | Storefront / catalog browse | `inventory`, Postgres | Postgres | latency, 500 |
| `customer-service` | `generate/customer/` | Customer profiles / accounts | Postgres | Postgres | latency, 500 |
| `order-service` | `generate/order/` | Front-door `POST /orders` orchestrator | `customer`, `inventory`, `payment`, `invoice`; NATS → `notification` | Postgres | DB slow query, 500 on validation |
| `inventory-service` | `generate/inventory/` | Reserves stock | Redis, then Postgres on miss | Redis + Postgres | cold-cache latency spike |
| `invoice-service` | `generate/invoice/` | Generates invoice / billing record | Postgres | Postgres | latency, 500 |
| `payment-service` | `generate/payment/` | Charges card (mocked) | in-process `mock-bank` (dummy) | — | timeout, sporadic 502 (**headline demo**) |
| `notification-service` | `generate/notification/` | Sends order confirmation | NATS subscriber (async) | NATS | slow consumer / backlog |
| `load-gen` | `generate/load-gen/` | Traffic generator (driver, not a service) | all front-door services | — | n/a — it's the driver |

**Chaos contract** (same on every service, internal network only, bearer-token gated):

- `POST /chaos/latency` — body `{ "ms": 2000, "duration_s": 60 }` — inject latency for the window
- `POST /chaos/error` — body `{ "rate": 0.3, "status": 502 }` — return that status for the given fraction of requests
- `POST /chaos/reset` — return to normal (the most-used lever in the demo; also wrapped by the `disable-chaos` runbook)

### store-service

- **Purpose:** storefront / catalog browse — the read-heavy front of the shop.
- **Endpoints:** catalog browse routes (e.g. list/get products); `GET /health`; `POST /chaos/{latency,error,reset}`.
- **Dependencies:** calls `inventory-service` for stock; reads Postgres (its own schema).
- **Infra:** Postgres.
- **Failure / chaos modes:** injected latency, HTTP 500.
- **Source:** `generate/store/`.

### customer-service

- **Purpose:** customer profiles and accounts (signup / lookup).
- **Endpoints:** profile/account routes; `GET /health`; `POST /chaos/{latency,error,reset}`.
- **Dependencies:** Postgres (its own schema). No downstream service calls.
- **Infra:** Postgres.
- **Failure / chaos modes:** injected latency, HTTP 500.
- **Source:** `generate/customer/`.

### order-service

- **Purpose:** the front-door orchestrator — `POST /orders` fans out across the mesh and is the entry point for the headline trace.
- **Endpoints:** `POST /orders` (orchestration); `GET /health`; `POST /chaos/{latency,error,reset}`.
- **Dependencies:** synchronous HTTP to `customer` (validate), `inventory` (reserve), `payment` (charge), `invoice` (bill); then publishes an order event to **NATS → `notification`** (async confirm). Persists to Postgres (its own schema).
- **Infra:** Postgres; NATS (publisher).
- **Failure / chaos modes:** DB slow query, HTTP 500 on validation.
- **Note:** the `order → notification` NATS hop must carry explicit OTel trace context in the message envelope so the async leg stays part of one connected trace (HTTP propagation is automatic; NATS is not).
- **Source:** `generate/order/`.

### inventory-service

- **Purpose:** reserves stock; the cold-cache latency story.
- **Endpoints:** stock check / reserve routes; `GET /health`; `POST /chaos/{latency,error,reset}`.
- **Dependencies:** reads Redis first, falls back to Postgres on a cache miss.
- **Infra:** Redis (cache) + Postgres. Its Redis cache is the target of the `clear-cache` runbook (`FLUSHDB`).
- **Failure / chaos modes:** cold-cache latency spike (cache miss → backend latency).
- **Source:** `generate/inventory/`.

### invoice-service

- **Purpose:** generates the invoice / billing record for an order.
- **Endpoints:** invoice generate / query / pay routes; `GET /health`; `POST /chaos/{latency,error,reset}`.
- **Dependencies:** Postgres (its own schema).
- **Infra:** Postgres.
- **Failure / chaos modes:** injected latency, HTTP 500.
- **Source:** `generate/invoice/`.

### payment-service

- **Purpose:** charges the card (mocked) against an **in-process `mock-bank`** that returns a dummy response — no real external call. **This is the headline demo chaos target.**
- **Endpoints:** charge route; `GET /health`; `POST /chaos/{latency,error,reset}`.
- **Dependencies:** none external — the `mock-bank` is simulated in-process. No database of its own.
- **Infra:** none.
- **Failure / chaos modes:** timeout, sporadic 502 — the demo injects ~30% 502 + 2s latency here to start the incident.
- **Source:** `generate/payment/`.

### notification-service

- **Purpose:** sends order confirmation; the async consumer leg of the mesh.
- **Endpoints:** internal/health routes; `GET /health`; `POST /chaos/{latency,error,reset}`. (Driven asynchronously, not by the load-gen directly.)
- **Dependencies:** NATS subscriber — consumes order events published by `order-service`.
- **Infra:** NATS.
- **Failure / chaos modes:** slow consumer / backlog (drives the async-backlog diagnosis scenario).
- **Source:** `generate/notification/`.

### load-gen

- **Purpose:** the traffic generator — a long-lived Ballerina worker (not a service) that keeps the mesh busy so the observability stack has something to show.
- **What it drives:** the five front-facing domains — `customer` (signup/lookup), `order` (`POST /orders` with varied SKUs + customer IDs), `invoice` (query/pay), `inventory` (stock check), `store` (catalog browse). `payment` and `notification` are exercised transitively through `order`.
- **Config:** reads YAML pattern files — `baseline.yaml`, `spike.yaml`, `regression.yaml` — plus per-domain flow definitions; selects one via the `--pattern baseline|spike|regression` CLI arg. Runs as a long-lived compose container defaulting to `baseline`.
- **Telemetry:** emits its own OTel spans so the generated load itself is visible in Datadog.
- **Source:** `generate/load-gen/`.

## Observability pipeline

All services emit OTLP natively (Ballerina observability module) to a **single OTel Collector** (OTLP gRPC `:4317` / HTTP `:4318`), which fans out by signal type:

| Signal | Destination | Why |
|---|---|---|
| Traces | **Datadog (APM) + Splunk (HEC)** | both ends of the correlation join |
| Logs | **Splunk (HEC)** | Splunk is the log-of-record (`DD_LOGS_ENABLED=false` to avoid double-billing) |
| Metrics | **Datadog** | Datadog is the metrics-of-record |

The Collector tags everything with `service.namespace=devops-poc` and `deployment.environment=demo`. The **join key** across systems is the structured-log `trace_id` / `span_id`: each service emits JSON logs carrying the active `trace_id` and `span_id`, so a trace seen in Datadog APM can be matched to its log lines in Splunk. Mind the trace-ID format mismatch — Datadog surfaces a 64-bit `dd.trace_id` alongside the 128-bit `otel.trace_id`; the Ballerina MCP correlation layer must handle both. See [`architecture.md`](architecture.md) for the full pipeline diagram and [`todo/phase-1-compose.md`](todo/phase-1-compose.md) for the Collector config.

## MCP servers

The agent reaches three MCP servers — two official, one custom — preferably fronted by a single WSO2 API Manager **MCP Gateway** that exposes three tool namespaces (auth / rate-limiting / audit "for free").

### Splunk MCP (official)

- **Server:** the official *MCP Server for Splunk platform* (Splunkbase app 7931, "Splunk Supported") — installed on your **Splunk Cloud** deployment, not run locally. Streamable HTTP at the app-generated HTTPS endpoint; auth via an MCP bearer token minted in the app (RBAC capability `mcp_tool_execute`).
- **Role / tools:** log search via SPL — `splunk_run_query` (e.g. `index=* trace_id="<id>"`), plus `splunk_get_indexes`, `splunk_get_knowledge_objects`. There's no per-trace tool — trace lookups are just SPL.
- **Wiring:** connection config under `agent/splunk/mcp/`. Splunk is a **Cloud trial** (not in the compose stack); telemetry ships there via the Collector's `splunk_hec` exporter.

### Datadog MCP (official)

- **Server:** the official *Datadog MCP Server* (Bits AI) — **remote-hosted** by Datadog at `https://mcp.datadoghq.com/api/unstable/mcp-server/mcp` (regional per `DD_SITE`; in Preview, under `/api/unstable/` — pin it). Streamable HTTP; auth via OAuth 2.0 or `DD_API_KEY` + `DD_APPLICATION_KEY` headers. Toolsets selected via `?toolsets=apm,...`.
- **Role / tools (real names):** metrics — `get_datadog_metric`, `search_datadog_metrics`; errors — `search_datadog_error_tracking_issues`; APM traces — `get_datadog_trace` (full trace by ID), `apm_search_spans`; logs — `search_datadog_logs`; monitors — `search_datadog_monitors`. (Our earlier `get_service_metrics` / `get_service_errors` were placeholder guesses — these are the actual tools.)
- **Wiring:** connection config under `agent/datadog/mcp/`.

### Ballerina MCP (custom)

The glue between Splunk and Datadog: it owns the **service catalog, dependency graph, cross-system correlation, and scoped runbook execution**. Built in Ballerina (so it can both *know* topology and *act* on it), it runs over **Streamable HTTP on `:8290`** (HTTP/SSE fallback). Source lives in `generate/mcp-server/`; the client-side wiring the agent uses to reach it is in `agent/mcp/`. Same OTel instrumentation as the mesh, so its own calls show up in Datadog. See [`todo/phase-3-mcp.md`](todo/phase-3-mcp.md).

**Tool catalog:**

| Group | Tool | Inputs | Returns |
|---|---|---|---|
| Lookup / topology | `lookup_service` | `name` | `{ owner, repo, runbook_ids, sla, health_endpoint, dependencies }` |
| Lookup / topology | `get_dependencies` | `name`, `direction` (`upstream`/`downstream`/`both`) | adjacency list (matches the Phase 2 topology) |
| Lookup / topology | `list_services` | (none) | all known services with `last_seen` |
| Lookup / topology | `get_service_health` | `name` | live `/health` probe — status + latency |
| Correlation | `correlate_trace` | `trace_id` | Datadog APM URL + Splunk search URL/SPL + involved services — **links + topology only, no vendor API calls**; the agent fetches data via the Splunk/Datadog MCPs |
| Correlation | `find_recent_deploys` | `service`, `lookback` | recent deploys from a stub deploy log ("did something change?") |
| Correlation | `find_related_incidents` | `service`, `lookback` | past incidents from a local SQLite stub (learning-from-history) |
| Runbooks | `list_runbooks` | (none) | array of `{ id, name, description, params_schema }` |
| Runbooks | `run_runbook` | `id`, `params` | streaming (SSE) progress of the execution |

**Runbooks shipped:**

| ID | Action |
|---|---|
| `restart-service` | restart a container / pod via the Docker/K8s API |
| `clear-cache` | Redis `FLUSHDB` on `inventory-service`'s cache |
| `disable-chaos` | call `POST /chaos/reset` on a target service (the demo's recovery lever) |
| `freeze-deploys` | set a flag in a stub deploy registry |

**Service catalog:** the source of truth is `catalog/services.yaml` — enumerates all seven mesh services with owner, slack channel, repo URL, runbook IDs, health endpoint, and declared dependencies. The dependency edges must match the Phase 2 topology exactly so `get_dependencies` returns the real graph (including the `order → notification` async edge).

**MCP Gateway (optional):** the server may be registered behind WSO2 API Manager's MCP Gateway. If used, auth is deferred to the gateway — but verify the gateway does **not** buffer SSE, or streaming `run_runbook` output breaks.

## Agent (client)

The incident-response **Python agent** (`agent/`) runs under WSO2 Agent Manager on Kubernetes/kind. See [`todo/phase-4-agent.md`](todo/phase-4-agent.md).

- **Framework / LLM:** Python, built on the **Claude Agent SDK** (native MCP client; first-class under Agent Manager). The LLM is **Anthropic Claude** — the SDK is Anthropic-native, which supersedes the earlier Ollama pick. Packaged via `agent/pyproject.toml` + `agent/Dockerfile` (Python 3.11).
- **MCP wiring:** connects to all three MCP servers — Splunk (`agent/splunk/mcp/`), Datadog (`agent/datadog/mcp/`), and the custom Ballerina MCP (client wiring in `agent/mcp/`, server in `generate/mcp-server/`). Preferred model: a **single API Manager MCP Gateway URL with three tool namespaces** (auth via the gateway); the fallback is three direct MCP connections each with its own URL + token.
- **Behavior / guardrail:** the system prompt drives a fixed triage loop — check the alert → pull recent metrics → correlate to logs by `trace_id` → consult topology for blast radius → **propose a runbook before running it** → summarize. The **propose-before-act** guardrail is hard: the agent must call `list_runbooks` and present its choice for human approval *before* it may call `run_runbook`. Max turns and budget caps are configured.
- **Triggers:** a **Datadog-monitor webhook** (`Datadog monitor → HTTP webhook → agent endpoint` — the realistic path used in the live demo) or the CLI `agent investigate --alert-id X` (the fallback).
- **Self-observability (the meta-win):** the agent is auto-instrumented by `amp-instrumentation` (injected at pod startup by the `amp-python-instrumentation-provider` init container — **no manual OTel**), so its full reasoning trace, per-LLM-call latency, token usage, and tool-call durations are visible in `amp-trace-observer`. The agent watches the workload while Agent Manager watches the agent.

---

## See also

- **[`CLAUDE.md`](CLAUDE.md)** — locked decisions, data flows, and known gotchas (trace-ID mismatch, NATS async propagation, SSE buffering, pod→compose reachability).
- **[`architecture.md`](architecture.md)** — the deep dive: topology diagrams, telemetry fan-out, correlation and remediation flows.
- **[`todo/README.md`](todo/README.md)** — the phased build plan and per-phase exit criteria.
