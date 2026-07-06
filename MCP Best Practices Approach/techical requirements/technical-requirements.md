# Technical Requirements Specification
## DevOps OverSight Agent — Point-in-Time Reverse-Engineered Requirements

**Generated**: 2026-07-02T21:59:48Z
**Source**: Reverse-engineered from existing codebase implementation (`DevOpsAgent`, Ballerina stack)
**Methodology**: First-order principles analysis
**Status**: Point-in-time snapshot — reflects system state as of generation date
**Warning**: This document describes requirements inferred from implementation. It is not a forward-looking design document. Actual business requirements may differ. Requirements use RFC 2119 keywords (MUST, MUST NOT, SHOULD, SHOULD NOT, MAY). Implementation-specific details (Ballerina constructs, library names) appear only in `> Implementation Note:` callouts.

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [System Context & Goals](#2-system-context--goals)
3. [Architectural Requirements](#3-architectural-requirements)
4. [Component Requirements](#4-component-requirements)
5. [Data Requirements](#5-data-requirements)
6. [Integration Requirements](#6-integration-requirements)
7. [API & Interface Specifications](#7-api--interface-specifications)
8. [Observability Requirements](#8-observability-requirements)
9. [Security Requirements](#9-security-requirements)
10. [Non-Functional Requirements](#10-non-functional-requirements)
11. [Testing Requirements](#11-testing-requirements)
12. [Deployment & Infrastructure Requirements](#12-deployment--infrastructure-requirements)
13. [Developer Experience Requirements](#13-developer-experience-requirements)
14. [Glossary](#14-glossary)

---

## 1. Executive Summary

The DevOps OverSight Agent is an AI-driven incident-response system that diagnoses and remediates production-style incidents by **correlating observability signals across two independent backends** — a logs/traces system (Splunk) and a metrics/APM system (Datadog) — over the Model Context Protocol (MCP). A single reasoning agent, driven by a configurable Large Language Model (LLM) in a native tool-use loop, investigates an alert end-to-end: it pulls metrics, retrieves a distributed trace, correlates that trace to log lines in the other system, assesses blast radius against a service dependency graph, rules out recent deploys, and then **proposes a bounded remediation runbook for human approval before acting**.

The system exists to demonstrate that the hardest part of incident response — **joining evidence from separate observability silos into one causal story** — is best solved by keeping all evidence in a single reasoning context, reached through one federating MCP entry point, rather than fragmenting it across multiple agents. It targets platform/SRE and observability engineering audiences evaluating agentic incident response, and its core value proposition is a repeatable, auditable, human-gated diagnosis-to-remediation loop that is itself fully observable (the agent's reasoning trace flows through the same telemetry pipeline as the workload it watches).

The reference workload is a seven-service retail microservice mesh plus a traffic generator, instrumented to emit traces, logs, and metrics. An operator injects a fault ("chaos") into a target service; a metrics monitor fires; the agent investigates; a human approves the proposed fix; the agent remediates; the mesh recovers. The entire scenario is designed to complete in approximately five minutes and to run fully offline against mock observability backends (no vendor credentials required), swapping to live backends via configuration alone.

---

## 2. System Context & Goals

### 2.1 Primary Objectives

- **PO-1** The system MUST diagnose an incident in a microservice mesh by correlating metrics, traces, and logs sourced from two distinct observability backends.
- **PO-2** The system MUST perform cross-system correlation using a shared distributed-trace identifier as the join key between the two backends.
- **PO-3** The system MUST assess incident blast radius using a service dependency graph.
- **PO-4** The system MUST propose a bounded, vetted remediation action and MUST obtain explicit human approval before executing any state-mutating action.
- **PO-5** The system MUST expose all observability capabilities to the reasoning agent through a single MCP entry point that federates the backends.
- **PO-6** The system MUST be operable end-to-end without live vendor credentials by substituting mock backends selected via configuration.
- **PO-7** The reasoning agent MUST itself emit telemetry (its reasoning steps, tool calls, and LLM-call latency) into the same pipeline as the workload.

### 2.2 Key Stakeholders and Needs

| Stakeholder | Need |
|---|---|
| Platform / SRE engineer | Fast, auditable diagnosis; human-in-the-loop remediation; a fixed allowlist of safe actions |
| Observability engineer | Correlation across log-of-record and metrics-of-record systems without double-billing signals |
| Service owner | Blast-radius awareness; ownership/on-call/runbook metadata per service |
| Demo operator | A repeatable ~5-minute scenario runnable offline; scripted fault injection and reset |
| Security / governance | A single chokepoint for tool calls; propose-before-act gate; auditable remediation |

### 2.3 Success Criteria

- **SC-1** Given an alert for a degraded service, the agent MUST invoke at least one tool from each of the three tool domains (topology/correlation, logs backend, metrics backend), propose the correct remediation runbook, and return a summary containing the involved trace identifier, the involved services, and evidence links to both backends.
- **SC-2** The full inject → alert → investigate → approve → remediate → recover cycle MUST be achievable within a ~5-minute target runtime.
- **SC-3** The mock-backed stack MUST stand up from a clean machine and pass health checks without external credentials.
- **SC-4** Swapping from mock to live backends MUST require configuration changes only (no source changes).

### 2.4 Out of Scope (Explicit Non-Requirements)

- **OOS-1** The system does NOT provide a generic command-execution ("run arbitrary CLI") tool. Remediation is limited to a fixed typed allowlist of runbooks.
- **OOS-2** The system does NOT implement production-grade identity, RBAC, or secret management; endpoints on the trusted local network are unauthenticated in this snapshot.
- **OOS-3** The system does NOT implement a multi-agent / agent-to-agent topology. Correlation is deliberately kept in one reasoning context.
- **OOS-4** The system does NOT implement semantic/vector-based tool discovery in this snapshot; a keyword scorer stands in.
- **OOS-5** The system does NOT bound, truncate, or sanitize tool results before returning them to the LLM (safe only because mock backends return small, trusted payloads).
- **OOS-6** The system does NOT persist audit logs, deploy-freeze state, or incident history durably; these are in-memory or stub data in this snapshot.

---

## 3. Architectural Requirements

### 3.1 System Topology

The system comprises two tiers:

- **Workload + observability tier** — the microservice mesh (seven services), a traffic generator, backing infrastructure (a relational database, a cache, an async message bus), a single telemetry collector, the MCP Proxy, and the two mock (or live) observability MCP backends.
- **Agent tier** — the reasoning agent, which connects to exactly one MCP endpoint (the MCP Proxy).

- **AR-1** The system MUST consist of the following logical components: (a) seven mesh services, (b) one traffic generator, (c) one telemetry collector, (d) one relational database, (e) one cache, (f) one async message bus, (g) one MCP Proxy, (h) one logs-backend MCP server, (i) one metrics-backend MCP server, (j) one reasoning agent.
- **AR-2** The reasoning agent MUST connect to exactly one MCP endpoint (the MCP Proxy). It MUST NOT connect directly to the logs or metrics backends.
- **AR-3** The MCP Proxy MUST federate the logs-backend and metrics-backend MCP servers, connecting to them as an MCP client, and MUST own the service-catalog, correlation, and runbook tools locally.

### 3.2 Communication Patterns

- **AR-4** Service-to-service calls within the mesh MUST be synchronous HTTP, except the order → notification confirmation hop, which MUST be asynchronous via the message bus.
- **AR-5** Telemetry MUST be emitted from all services to the collector using OpenTelemetry Protocol (OTLP) over gRPC (and MUST also support OTLP over HTTP at the collector).
- **AR-6** All MCP traffic (agent → proxy, proxy → backends) MUST use JSON-RPC 2.0 over HTTP POST to a single `/mcp` route (MCP "Streamable HTTP" transport). Responses MUST carry `Content-Type: application/json`.
- **AR-7** LLM calls MUST be made over HTTP directly to the selected provider's API (no vendor SDK dependency required).

### 3.3 Deployment Model

- **AR-8** Every component MUST be containerized and orchestratable together as a single stack on one bridge network.
- **AR-9** The agent tier MUST be deployable either co-located in the same stack or on a separate orchestrator; when separated it MUST reach the proxy over a host-routable network endpoint.
- **AR-10** The mock-vs-live backend selection MUST be a configuration change on the **proxy** (backend URLs), never on the agent.

### 3.4 Scalability & Availability (as inferred)

- **AR-11** The MCP Proxy MUST tolerate backend MCP servers being unavailable at startup: it MUST log a warning and retry federation on subsequent requests rather than failing fatally.
- **AR-12** The agent MUST tolerate any MCP backend being unavailable at startup: it MUST degrade gracefully and continue with the tools available from reachable servers.
- **AR-13** The telemetry collector MUST apply back-pressure protection (a memory limiter) and batching so it survives sustained load.

> **Implementation Note:** This snapshot is single-node. Multi-AZ, autoscaling, an event-bus alert intake, a mandatory MCP gateway, CMDB-backed catalog, and org-boundary agent-to-agent decomposition are documented as the production evolution but are NOT implemented here.

---

## 4. Component Requirements

### 4.0 Component Catalog & Port Map

| Component | Purpose | Business port (container) | Auxiliary ports |
|---|---|---|---|
| store-service | Storefront / catalog browse | 9090 | chaos 9099; metrics 9797 |
| customer-service | Customer profiles / accounts | 9090 | chaos 9099; metrics 9797 |
| order-service | Order orchestrator (fan-out) | 9090 | chaos 9099; metrics 9797 |
| inventory-service | Stock reserve (cache-then-DB) | 9090 | chaos 9099; metrics 9797 |
| invoice-service | Invoice / billing record | 9090 | chaos 9099; metrics 9797 |
| payment-service | Card charge (in-process mock bank) | 9090 | chaos 9099; metrics 9797 |
| notification-service | Async order confirmation | 9090 (health only) | chaos 9099; metrics 9797 |
| load-gen | Traffic generator (no listener) | — | metrics 9797 |
| mcp-proxy | Single MCP entry point + federation | 8290 (`/mcp`, `/health`) | metrics 9797 |
| logs-backend MCP (mock) | Logs/SPL search | 8400 (`/mcp`, `/health`) | — |
| metrics-backend MCP (mock) | Metrics/APM/monitors | 8401 (`/mcp`, `/health`) | — |
| agent | Reasoning agent + trigger endpoints | 8000 (`/health`, `/investigate`, `/chat`, `/webhook/alert`) | metrics 9797 |
| telemetry collector | OTLP fan-out | 4317 (gRPC), 4318 (HTTP) | — |
| relational DB | Backing store (DB-per-service) | 5432 | — |
| cache | Inventory cache | 6379 | — |
| message bus | Async order events | 4222 (client), 8222 (monitoring) | — |

> **Implementation Note:** In this snapshot each mesh business port 9090 is published to distinct host ports 9091–9097 and each chaos port 9099 to host 9191–9197 (payment = host 9196). The agent listens on container port 8000, published to host 8092 (host 8080/8082 are avoided due to a local VM port-forward collision).

---

### 4.1 Mesh Services — Common Requirements

All seven mesh services share the following requirements.

- **MS-1** Each service MUST expose its business HTTP routes and a liveness route `GET /health` on one business listener (port 9090).
- **MS-2** Each service MUST expose a **separate** chaos-control listener (port 9099) so chaos control remains reachable even when the business listener is under injected latency or errors.
- **MS-3** `GET /health` MUST return HTTP 200 with body `{ "status": "UP", "service": "<name>-service" }`.
- **MS-4** Each service's OTel service name MUST be `<directory>-service` (the `-service` suffix is load-bearing — the catalog, correlation, and demo reference services by that exact name).
- **MS-5** Each service MUST emit structured JSON logs, and every log line MUST carry the active trace identifier and span identifier under the field names `trace_id` and `span_id` (empty strings when outside a span). See §8.2.
- **MS-6** Each service MUST propagate W3C trace-context automatically across synchronous HTTP calls.
- **MS-7** Database queries MUST surface as child spans (DB-connector tracing MUST be enabled); otherwise DB latency is invisible in traces.

#### 4.1.1 Chaos Contract (byte-identical across all seven services)

- **CH-1** The chaos listener MUST expose `POST /chaos/latency`, `POST /chaos/error`, and `POST /chaos/reset`.
- **CH-2** All chaos endpoints MUST require a header `X-Chaos-Token` whose value equals a configured token (default `dev-chaos-token`, from env `CHAOS_TOKEN`). A missing or mismatched token MUST return HTTP 403.
- **CH-3** `POST /chaos/latency` MUST accept body `{ "ms": integer, "duration_s": integer (default 60) }`, set an injected-latency window ending at `now + duration_s`, and return `200 { "status": "latency injected", "ms": integer, "duration_s": integer }`.
- **CH-4** `POST /chaos/error` MUST accept body `{ "rate": decimal, "status": integer (default 502), "duration_s": integer (default 60) }`, set an injected-error window ending at `now + duration_s`, and return `200 { "status": "error injected", "rate": decimal, "errorStatus": integer }`.
- **CH-5** `POST /chaos/reset` MUST clear both windows and return `200 { "status": "reset" }`.
- **CH-6** Every business handler MUST evaluate injected chaos before its normal logic:
  - If a latency window is active and latency > 0, the handler MUST block for the configured milliseconds before proceeding.
  - If an error window is active and a per-request random draw is below the configured rate, the handler MUST return the injected HTTP status with body `{ "error": "chaos-injected", "status": integer }`.
- **CH-7** The async consumer (notification-service) MUST evaluate injected latency in its message handler (error injection has no HTTP response to fail; only latency applies).

#### 4.1.2 Per-Service Behavioral Requirements

**store-service** — Storefront/catalog.
- MUST expose `GET /products` → array of `{ id:integer, name:string, sku:string, price:decimal }`.
- MUST expose `GET /products/{id}` → `{ id, name, sku, price, stock:integer?, availability:string }` (`availability` ∈ `in_stock` | `out_of_stock` | `unknown`) or 404.
- MUST call inventory-service `GET /stock/{sku}` best-effort; on failure it MUST degrade `availability` to `unknown` rather than fail.
- Dependencies: relational DB (`storedb`), inventory-service.

**customer-service** — Profiles/accounts.
- MUST expose `POST /customers` (body `{ name:string, email:string }`) → `{ id, name, email }`.
- MUST expose `GET /customers/{id}` → `{ id, name, email }` or 404 (order-service validation depends on the 404).
- Dependencies: relational DB (`customerdb`). No downstream service calls.

**order-service** — Front-door orchestrator (see §4.1.3).
- MUST expose `POST /orders` (body `{ customerId:integer, items:[{ sku:string, qty:integer }] }`) → `{ orderId:string, status:"confirmed", total:decimal }`.
- Error responses (all with body `{ "error": string }`): 400 invalid customer, 409 insufficient/failed stock, 502 payment failed or billing failed, 503 DB unavailable, 500 persist failed.
- Dependencies: relational DB (`orderdb`); synchronous HTTP to customer, inventory, payment, invoice; asynchronous publish to notification via the message bus.

**inventory-service** — Stock reserve (see §4.1.4).
- MUST expose `GET /stock/{sku}` → `{ sku, qty:integer, source:"cache"|"db" }` | 404 | 500.
- MUST expose `POST /reserve` (body `{ sku:string, qty:integer }`) → `{ sku, reserved:boolean, remaining:integer }` | 404 | 500 | 503.
- MUST reserve only when `qty > 0 && current >= qty`.
- Dependencies: relational DB (`inventorydb`), cache.

**invoice-service** — Billing record.
- MUST expose `POST /invoices` (body `{ orderId:string, amount:decimal }`, validating non-empty orderId and amount > 0) → `{ invoiceId:integer, orderId, amount, status:"issued" }`.
- MUST expose `GET /invoices/{id}` → invoice | 404, and `POST /invoices/{id}/pay` → invoice with `status:"paid"` | 404.
- Dependencies: relational DB (`invoicedb`).

**payment-service** — Card charge (headline chaos target; see §4.1.5).
- MUST expose `POST /charge` (body `{ amount:decimal, currency:string (default "USD"), orderId:string }`) → `{ paymentId:string, status:string, amount:decimal, authId:string, note:string }`.
- MUST authorize against an **in-process** mock bank that performs no I/O and always approves. Failures (502 / timeout) MUST come solely from the chaos mechanism, not the mock bank.
- Dependencies: none (no DB, no downstream).

**notification-service** — Async confirmation.
- MUST expose only `GET /health` over HTTP (it is an async consumer).
- MUST subscribe to the order-created subject on the message bus, extract trace-context from the message envelope, and log a confirmation. Bus unavailability MUST degrade gracefully (warn, no crash).

#### 4.1.3 Order Orchestration & Async Leg

- **ORD-1** `POST /orders` MUST execute a sequential, fail-fast fan-out: chaos gate → generate order id → validate customer (sync) → reserve each item (sync) → charge payment (sync) → create invoice (sync) → persist order → publish async confirmation.
- **ORD-2** Any non-2xx / error from the payment call MUST map to order 502 "payment failed" (this is the headline failure path). Any non-2xx / error from invoice MUST map to 502 "billing failed". Invalid customer MUST map to 400; failed reservation to 409; persist failure to 503/500.
- **ORD-3** The order total MUST be computed from a fixed unit price per item quantity, and the order id MUST be a unique string of the form `ORD-<millis>-<random>`.
- **ORD-4** The async confirmation MUST be published **after** the order is committed and MUST be non-fatal (a publish failure MUST NOT fail the order).
- **ORD-5** The message envelope MUST be JSON `{ orderId:string, customerId:integer, total:decimal, traceparent:string }` on a fixed subject (`orders.created`).
- **ORD-6** Because the message bus does not auto-propagate trace-context, the publisher MUST inject a W3C `traceparent` string of the form `00-<32-hex traceId>-<16-hex spanId>-01` derived from the active span, and the consumer MUST parse it (validating: 4 dash-separated parts, version `00`, 32-hex trace id, 16-hex span id, lowercase hex) so the async leg joins the same trace. Malformed envelopes MUST be logged and dropped.

> **Implementation Note:** The envelope types `customerId` as integer on publish; the consumer coerces it to string. A re-implementation SHOULD standardize the type.

#### 4.1.4 Inventory Cache Pattern

- **INV-1** Reads MUST consult the cache first (key `stock:<sku>`); on hit return with `source:"cache"`.
- **INV-2** On miss or cache error (logged, treated as miss), reads MUST fall back to the relational DB (`source:"db"`), then best-effort populate the cache.
- **INV-3** Reservations MUST treat the relational DB as authoritative (decrement under the DB), then best-effort refresh the cache; on cache-write failure the entry MUST be invalidated (deleted). Cache unavailability MUST degrade gracefully.

#### 4.1.5 Payment Mock Bank

- **PAY-1** The mock bank MUST be a pure in-process function returning an approval `{ authId:"AUTH-<uuid>", approved:true, note:string }`; the charge response `status` MUST be `"approved"` when approved.
- **PAY-2** 502 responses and timeouts MUST be produced only by the chaos mechanism (error injection → 502; latency injection → simulated timeout), never by the mock bank.

### 4.2 Traffic Generator (load-gen)

- **LG-1** load-gen MUST be a long-lived worker (not an HTTP service) that drives the five front-facing domains (store, customer, inventory, invoice, order); payment and notification MUST be exercised transitively through order.
- **LG-2** It MUST select a traffic pattern via CLI argument `--pattern <name>` or env `LOADGEN_PATTERN` (default `baseline`), loading a pattern definition from a file.
- **LG-3** A pattern MUST define `{ name:string, baseRps:integer, workers:integer, durationSeconds:integer (0 = forever), spike?:{ afterSeconds:integer, rps:integer, forSeconds:integer }, weights:{ store, customer, inventory, invoice, order : integer } }`.
- **LG-4** It MUST run `workers` concurrent strands, pace each strand so aggregate throughput approximates the current RPS, apply the spike window when configured, and pick a domain per iteration by cumulative weight.
- **LG-5** It MUST emit its own telemetry so generated load is visible.
- **LG-6** It MUST ship at least three patterns with these exact values:

| pattern | baseRps | workers | duration | spike | weights (store/customer/inventory/invoice/order) |
|---|---|---|---|---|---|
| baseline | 5 | 4 | 0 | none | 30/15/25/10/20 |
| spike | 5 | 6 | 0 | after 60s, rps 25, for 60s | 25/10/20/5/40 |
| regression | 8 | 6 | 0 | none | 20/5/45/5/25 |

### 4.3 MCP Proxy

The MCP Proxy is simultaneously an MCP **server** (facing the agent) and an MCP **client** (facing the backends).

- **PX-1** The proxy MUST expose one HTTP listener hosting `GET /health` (returning `{ "status":"UP", "service":"mcp-proxy" }`, unauthenticated) and `POST /mcp`.
- **PX-2** `POST /mcp` MUST implement JSON-RPC 2.0, dispatching by `method`:
  - `initialize` → `result { protocolVersion:"2024-11-05", capabilities:{ tools:{} }, serverInfo:{ name, version } }`
  - `notifications/initialized` → `result {}`
  - `ping` → `result {}`
  - `tools/list` → the tool list (see PX-4)
  - `tools/call` → route the named tool (see PX-6)
  - any other → JSON-RPC error `{ code:-32601, message:"Method not found: <method>" }`
  - All responses MUST carry `jsonrpc:"2.0"` and echo the request `id`.
- **PX-3** Before serving `tools/list` or `tools/call`, the proxy MUST attempt federation (lazy connect): register topology tools unconditionally (no network), then connect to each backend and register its tools under a namespace prefix. Federation MUST latch ready only when both backends have connected; otherwise it MUST retry on the next request.
- **PX-4** `tools/list` MUST return **only** `discover_tools` plus the topology tools (§4.3.1). It MUST NOT return the federated backend tools — those are revealed only via `discover_tools` (lazy loading). Each item MUST be `{ name, description, inputSchema }`.
- **PX-5** `tools/call` results MUST be returned as `result { content:[{ type:"text", text:<stringified JSON> }], isError:boolean }`; tool errors MUST be returned as JSON-RPC error `{ code:-32603, message }`.
- **PX-6** Tool routing MUST split the tool name on the first `__` separator: prefix = origin, remainder = real name (no separator ⇒ origin `topology`). Origin `splunk`/`datadog` MUST forward to the corresponding backend (real name only); otherwise the proxy MUST dispatch locally.
- **PX-7** Forwarding to an unavailable backend MUST return an error `"<label> MCP backend is unavailable (not connected). Retry shortly."` rather than crash.

#### 4.3.1 Proxy Tools (exact names, schemas)

Namespaces: `topology__` (local), `splunk__` (logs backend), `datadog__` (metrics backend); separator `__`.

| Tool | Input (fields:type, required) | Output payload |
|---|---|---|
| `discover_tools` | `{ query:string }`, req `[query]` | See §4.3.2 |
| `topology__lookup_service` | `{ name:string }`, req `[name]` | Full `ServiceInfo` (§5.4), or text "Not found: <name>. Known: <list>" |
| `topology__get_dependencies` | `{ name:string, direction:string ∈ upstream\|downstream\|both }`, req `[name,direction]` | `{ service, direction, dependencies:[string] }` |
| `topology__list_services` | `{}` | array of `{ name, owner, sla }` |
| `topology__get_service_health` | `{ name:string }`, req `[name]` | `{ service, status, httpStatus }` where status ∈ UP(200)/DEGRADED(non-200)/DOWN(error)/UNKNOWN; unknown service → text |
| `topology__correlate_trace` | `{ trace_id:string }`, req `[trace_id]` | See §4.3.3 |
| `topology__find_recent_deploys` | `{ service:string, lookback_minutes:integer (default 60) }`, req `[service]` | `{ service, lookback_minutes, deploys:[DeployRecord] }` |
| `topology__find_related_incidents` | `{ service:string, lookback_days:integer (default 30) }`, req `[service]` | `{ service, lookback_days, incidents:[IncidentRecord] }` |
| `topology__list_runbooks` | `{}` | array of `{ id, name, description, paramsSchema }` |
| `topology__run_runbook` | `{ id:string, params:object }`, req `[id]` | `{ runbook:id, steps:[string] }`; error → JSON-RPC error |
| `topology__get_audit_log` | `{}` | `{ entries:[string] }` |
| `topology__get_deploy_freeze_status` | `{}` | `{ frozen:boolean, reason:string }` |

`DeployRecord`: `{ service, version, deployedAt, deployedBy, gitSha, status }`. `IncidentRecord`: `{ id, service, title, severity, occurredAt, rootCause, resolution }`.

#### 4.3.2 Lazy Discovery (`discover_tools`)

- **PX-8** The proxy MUST maintain a server-side tool registry keyed by full namespaced name, each entry `{ name, description, inputSchema }`, populated during federation.
- **PX-9** `discover_tools(query)` MUST score every registry entry against the query and return the top matches (default up to 5) as stringified `{ tools:[{ name, description, input_schema }] }`. An empty query MUST return guidance text; zero matches MUST return "no tools matched" guidance.
- **PX-10** The scorer MUST operate over lowercased `"<name> <description>"`: for each query word longer than 2 characters, +2 for an exact substring match, else +1 if the word length ≥ 5 and its first-4-character prefix appears (stemming). Entries scoring 0 MUST be excluded; results MUST be sorted by descending score.

> **Implementation Note:** The registry uses field name `inputSchema`, but `discover_tools` output uses `input_schema` (underscore). A vector/embedding-based scorer is the documented future upgrade; a keyword scorer stands in and is accurate enough for the ~21-tool scale.

#### 4.3.3 Trace Correlation

- **PX-11** `correlate_trace(trace_id)` MUST return `{ trace_id, datadog_url, splunk_search_url, splunk_spl, involved_services, note }` where:
  - `datadog_url` = `https://app.<dd_site>/apm/trace/<trace_id>` (dd_site from config, default `datadoghq.com`; MUST NOT be hardcoded).
  - `splunk_spl` = `index=* trace_id="<trace_id>" | table _time, service, trace_id, span_id, message | sort -_time`.
  - `splunk_search_url` = `<splunk_base>/search?q=<url-encoded SPL>`.
  - `involved_services` = the catalog-derived list of services on the trace.
  - `note` instructs the agent to fetch actual data via the backend tools.
- **PX-12** `correlate_trace` MUST return **links and topology only**. It MUST NOT call vendor REST APIs; the agent fetches data via the backend MCP tools.
- **PX-13** The correlation layer MUST tolerate both 64-bit and 128-bit trace-identifier forms (the metrics backend surfaces a 64-bit id alongside the 128-bit id; the logs backend holds the 128-bit form). Failing to reconcile the two widths causes false "no logs found" conclusions and is the single most important correctness detail in the pipeline.

> **Implementation Note:** In this snapshot the trace id is substituted verbatim into both links with no width normalization, and `involved_services` is populated only for the exact demo trace id. A production re-implementation MUST implement true 64/128-bit reconciliation (see §6.4).

#### 4.3.4 Runbooks

- **PX-14** The proxy MUST expose exactly this fixed, typed allowlist of runbooks (no generic execute tool):

| id | Params (required) | Action |
|---|---|---|
| `restart-service` | `{ service:string }` | Restart the service's container/pod |
| `clear-cache` | `{}` | Flush the inventory cache |
| `disable-chaos` | `{ service:string }` | Call `POST /chaos/reset` on the target service (the demo recovery lever) |
| `freeze-deploys` | `{ reason:string }` | Set a deploy-freeze flag with the reason |

- **PX-15** `disable-chaos` MUST derive the target host, call the target's chaos-reset endpoint with the configured chaos token header, and record the HTTP result. It is the only runbook that performs a live external action in this snapshot; the others MAY be stubbed.
- **PX-16** `run_runbook` MUST coerce all `params` values to strings, execute the runbook, timestamp each step (UTC), append an audit entry, and return `{ runbook:id, steps:[string] }`. An unknown id MUST error.
- **PX-17** Audit entries MUST record runbook id and salient params (e.g. `<ts> RUNBOOK disable-chaos service=<svc>`) and MUST be retrievable via `get_audit_log`.
- **PX-18** The deploy-freeze state (`frozen`, `reason`) MUST be readable via `get_deploy_freeze_status` and settable via `freeze-deploys`.

> **Implementation Note:** "Streaming" runbook progress is expressed as the synchronous ordered `steps[]` array — there is no SSE at the transport layer in this snapshot, though the design anticipates SSE. There are no per-runbook idempotency locks; concurrency safety is only via isolated locked state. Audit log and freeze state are in-memory (not persisted).

### 4.4 Logs-Backend MCP (mock: logs/SPL)

- **LB-1** MUST serve MCP JSON-RPC 2.0 at `POST /mcp` and `GET /health` → `{ "status":"UP", "service":"<name>" }`.
- **LB-2** MUST implement tools: `splunk_run_query`, `splunk_get_indexes`, `splunk_get_knowledge_objects`, `splunk_describe_query`.
- **LB-3** `splunk_run_query` (req `[query]`; optional `earliest`, `latest`, `max_results` default 100) MUST return `{ query, result_count:integer, events:[LogEvent] }` filtered from a fixed corpus. Filtering MUST support: substring `trace_id=<value>` (prefix match on the first characters of the id), and error/status ≥ 400 filtering when the query mentions `502` or `error`. `max_results` MUST bound the returned events.
- **LB-4** `splunk_get_indexes` MUST return a fixed array of index names. `splunk_get_knowledge_objects` MUST return an array of `{ name, search }`. `splunk_describe_query` MUST return `{ query, explanation, estimated_events:integer }`.

`LogEvent`: `{ _time:string(ISO-8601), service:string, trace_id:string(32-hex), span_id:string(16-hex), message:string, status:integer, latency_ms:integer }`.

### 4.5 Metrics-Backend MCP (mock: metrics/APM/monitors)

- **MB-1** MUST serve MCP JSON-RPC 2.0 at `POST /mcp` and `GET /health`.
- **MB-2** MUST implement tools: `get_datadog_metric`, `search_datadog_metrics`, `search_datadog_error_tracking_issues`, `get_datadog_trace`, `apm_search_spans`, `search_datadog_logs`, `search_datadog_monitors`, `get_datadog_dashboard`.
- **MB-3** `get_datadog_metric` (req `[metric_name]`) MUST return a `MetricSeries` on hit, or `{ metric, series:[], note }` on miss. `search_datadog_metrics` (req `[query]`) MUST return matching metric descriptors. `get_datadog_trace` (req `[trace_id]`) MUST return the full `TraceData` when the id matches the demo trace, else `{ trace_id, spans:[], note }`. `apm_search_spans` MUST filter the demo trace's spans by service/operation substring. `search_datadog_error_tracking_issues`, `search_datadog_logs`, and `search_datadog_monitors` MUST return their fixed corpora filtered by an optional query. `get_datadog_dashboard` (req `[dashboard_id]`) MUST synthesize a dashboard descriptor.

`MetricSeries`: `{ metric:string, display_name:string, unit:string, series:[{ timestamp:integer, value:decimal }] }`. `ApmSpan`: `{ service:string, operation:string, duration_ms:integer, status:string(ok|error), error:string|null }`. `TraceData`: `{ trace_id:string, spans:[ApmSpan], services:[string] }`. `MonitorRecord`: `{ id, name, status, type, tags:[string] }`. `LogRecord`: `{ timestamp:string, service:string, message:string, status:string, trace_id:string }`.

- **MB-4** Both mock backends MUST model the headline incident: a payment-service `POST /charge` returning 502 with elevated (~2s+) latency, cascading into order-service, all sharing one demo trace id, with a corresponding fired monitor, error-tracking issues, error-rate/latency metric spikes, and matching log lines.

> **Implementation Note:** Both mock backends read **no** environment variables — all data is hardcoded; the mock-vs-live swap is done by pointing the proxy at a different URL. Trace ids are 128-bit (32 lowercase hex); span ids are 64-bit (16 hex). Lookups are prefix-based (logs backend matches the first 8 hex; metrics backend matches a 6-char prefix), so any demo trace id MUST share the expected prefix.

### 4.6 Reasoning Agent

- **AG-1** The agent MUST expose one HTTP listener (port 8000) hosting `GET /health`, `POST /investigate`, `POST /chat`, and `POST /webhook/alert` (see §7.1). The listener idle timeout MUST be long enough for multi-minute investigations.
- **AG-2** The agent MUST connect to exactly one MCP endpoint (the proxy), seed its active tool set from the proxy's `tools/list` (discover_tools + topology tools only), and open no other MCP clients.
- **AG-3** The agent MUST run a native tool-use loop: send the system prompt + conversation + current tool list to the LLM, dispatch any requested tool calls to the proxy, append results, and repeat until the LLM ends its turn or a maximum turn count is reached.
- **AG-4** The maximum turn count MUST be at least 25 (this snapshot uses 30). If reached without a terminal message, the agent MUST return the sentinel text "Investigation incomplete — max turns reached."
- **AG-5** All tool calls MUST be forwarded to the proxy; a tool error MUST be returned to the LLM as a `"Tool error: <message>"` string (fed back into the loop, not fatal).
- **AG-6** When the LLM calls `discover_tools`, the agent MUST parse the returned manifest bundle and fold any newly discovered tools into its active tool set (deduped by name), so they are callable on subsequent turns; the tool list MUST be rebuilt from the active set on every turn.
- **AG-7** The agent's system prompt MUST drive a 10-step investigation protocol: (1) find monitors → (2) pull metrics/error-rate → (3) get a trace → (4) correlate the trace → (5) query logs with the correlation SPL → (6) assess blast radius via dependencies → (7) rule out recent deploys → (8) check incident history → (9) **propose a runbook and WAIT for human approval** → (10) summarize (what failed, why, what was done, evidence links).
- **AG-8** The agent MUST enforce a **propose-before-act** guardrail: it MUST call `list_runbooks` and present its chosen runbook for explicit human approval before it may call `run_runbook`.
- **AG-9** The agent MUST support at least four interchangeable LLM providers selectable by a single configuration value (see §6.1), with no source change required to switch, including local, credential-free operation as the default demo path.
- **AG-10** The agent MUST emit its own telemetry (reasoning steps as spans, per-LLM-call latency, tool-call durations, token counts) through the same collector as the workload.

> **Implementation Note:** The propose-before-act guardrail is enforced at the prompt level in this snapshot — there is no code-level interception of `run_runbook`. A production re-implementation SHOULD add a hard gate. The output diagnosis "contract" is a free-text `summary` string, not a structured schema; the design notes a typed diagnosis contract as the durable production bet.

---

## 5. Data Requirements

### 5.1 Persistent Entities (relational DB, one logical database per service)

| Database | Table | Fields |
|---|---|---|
| storedb | products | id (serial PK), name (text), sku (text), price (numeric) |
| customerdb | customers | id (serial PK), name (text), email (text) |
| orderdb | orders | id (text PK, `ORD-…`), customer_id (int), total (numeric), status (text) |
| inventorydb | stock | sku (text PK), qty (int) |
| invoicedb | invoices | id (serial PK), order_id (text), amount (numeric), status (text) |

- **DR-1** The system MUST use one logical database per stateful service so a slow query in one service does not muddy another service's telemetry.
- **DR-2** Each service MUST create its own table(s) idempotently at startup (create-if-not-exists); databases MUST be created once at DB initialization.
- **DR-3** payment-service and notification-service MUST have no database. inventory-service MUST use its database only on cache miss/for authoritative writes.

### 5.2 In-Memory / Ephemeral State

- **DR-4** The proxy's tool registry, runbook audit log, and deploy-freeze state MUST be maintained under concurrency-safe isolation. These MAY be non-durable in this snapshot (lost on restart).

### 5.3 Stub / Reference Data

- **DR-5** The service catalog (§5.4), recent-deploys log, and incident history MUST be available to the correlation tools. In this snapshot they are static/stub data; production would source the catalog from a CMDB.

### 5.4 Service Catalog Schema

`ServiceInfo` (all fields required): `name:string`, `owner:string`, `slackChannel:string`, `repoUrl:string`, `healthEndpoint:string`, `dependencies:[string]`, `runbookIds:[string]`, `sla:string`.

- **DR-6** The catalog MUST enumerate all seven mesh services with their owner, chat channel, repo, health endpoint, declared synchronous dependencies, applicable runbook ids, and SLA. Async dependency edges (order → notification) MUST be modeled separately from synchronous dependencies but MUST be included in dependency resolution.
- **DR-7** Dependency resolution MUST support `downstream` (a service's dependencies + async edges), `upstream` (services depending on the named service), and `both`.

Catalog contents (this snapshot):

| name | owner | channel | dependencies (sync) | runbook ids | sla |
|---|---|---|---|---|---|
| store-service | store-team | #store | inventory-service | restart-service, disable-chaos | 99.9% |
| customer-service | customer-team | #customer | — | restart-service, disable-chaos | 99.95% |
| order-service | order-team | #order | customer, inventory, payment, invoice, notification | restart-service, disable-chaos, freeze-deploys | 99.9% |
| inventory-service | inventory-team | #inventory | — | restart-service, disable-chaos, clear-cache | 99.9% |
| invoice-service | finance-team | #finance | — | restart-service, disable-chaos | 99.5% |
| payment-service | payments-team | #payments | — | restart-service, disable-chaos | 99.99% |
| notification-service | platform-team | #platform | — | restart-service, disable-chaos | 99.5% |

Async edge: order-service → notification-service (via message bus).

### 5.5 Data Flow

- **DR-8** Telemetry MUST flow: services → collector → fan-out (traces to both backends; logs to the logs backend only; metrics to the metrics backend only). The join key across backends MUST be the `trace_id`/`span_id` in structured logs.
- **DR-9** A request flow MUST produce one connected distributed trace spanning the synchronous HTTP fan-out and the async confirmation leg (via injected `traceparent`).

### 5.6 Retention & Lifecycle

- **DR-10** Ephemeral state (audit log, freeze flag, registry) has process lifetime only. Persistent entities live for the DB volume's lifetime. This snapshot defines no explicit retention policy.

---

## 6. Integration Requirements

### 6.1 LLM Providers

- **IR-1** The agent MUST select its LLM provider by a single configuration value `LLM_PROVIDER` ∈ `ollama` (default in the stack), `anthropic`, `openai`, `amp`, and MUST validate provider readiness at startup without crashing the health endpoint on failure.
- **IR-2** Each provider MUST implement the tool-use loop with the provider's native wire shape:

| Provider | Endpoint | Auth | Default model | Tool-arg encoding |
|---|---|---|---|---|
| anthropic | `POST <base>/v1/messages` (base default public API; overridable — an AI-gateway may inject the base URL) | header `x-api-key` + `anthropic-version` | claude-sonnet-4-6 | tool inputs as objects; loop on `stop_reason` (`tool_use`/`end_turn`) with `content` blocks and `tool_result` blocks |
| ollama | `POST <base>/api/chat` (default local endpoint) | none | qwen3.5:9b | tools as `{type:function, function:{name,description,parameters}}`; tool-call arguments as JSON objects; `stream:false` |
| openai | `POST <base>/v1/chat/completions` | `Authorization: Bearer` (when key present) | gpt-4o | tool-call arguments as JSON string OR object (both handled); results as `{role:tool, tool_call_id, content}` |
| amp | `POST <base>/v1/chat/completions` (base injected by the gateway; required) | optional bearer (gateway may handle auth) | gpt-4o | same as openai |

- **IR-3** The Anthropic request MUST send `{ model, max_tokens, system, messages, tools }` with a bounded `max_tokens` (this snapshot: 8192). The OpenAI/AMP and Ollama loops MUST rebuild the tool list each turn.
- **IR-4** The Ollama provider MUST verify the daemon and, if the configured model is absent, MUST pull it before proceeding (credential-free path).
- **IR-5** A gateway-injected base URL (e.g. an AI gateway in front of Anthropic or an OpenAI-compatible gateway) MUST be honored when present and MUST NOT be set in local configuration by default (absent locally ⇒ fall back to the public endpoint).

### 6.2 Observability Backends (MCP)

- **IR-6** The proxy MUST reach the logs and metrics backends via configurable URLs (`SPLUNK_MCP_URL`, `DATADOG_MCP_URL`) defaulting to the in-stack mocks, and swapping to live vendor MCP servers MUST require only changing those URLs on the proxy.
- **IR-7** The proxy's MCP client MUST perform the `initialize` handshake (protocol version `2024-11-05`), send `notifications/initialized`, list tools, and call tools via JSON-RPC, detecting JSON-RPC errors and empty results.

> **Implementation Note:** Live vendor MCP servers use different auth (OAuth or API+application-key headers for the metrics vendor; a minted bearer token for the logs vendor). The MCP client's auth header MUST be parameterizable when switching from mock to live.

### 6.3 Telemetry Egress

- **IR-8** In live mode the collector MUST export traces to both backends, logs to the logs backend via its HTTP event collector, and metrics to the metrics backend, using credentials supplied by configuration. Log collection at the metrics vendor MUST be disabled to avoid double-billing.

### 6.4 Trace-ID Reconciliation (integration correctness)

- **IR-9** Because the metrics backend historically uses 64-bit trace ids while OTel/logs use 128-bit, the correlation path MUST normalize/handle both so a trace seen in the metrics UI can be found in the logs backend. (See PX-13.)

### 6.5 Mock / Development Fallback

- **IR-10** The system MUST provide mock implementations of both observability backends that require no credentials and return deterministic incident data, selected by default, so the full investigation loop is exercisable offline.

---

## 7. API & Interface Specifications

### 7.1 Agent HTTP API (port 8000)

**GET /health** → 200 `{ "status":"UP", "service":"devops-oversight-agent" }`.

**POST /investigate** — request `{ service:string (required), severity:string (default "P2"), description:string (default "Incident detected"), id:string (default "AGENT-001") }`; response 200 `{ "status":"investigated", "alert_id":string, "summary":string }`; 500 on parse/LLM error.

**POST /webhook/alert** — tolerant extraction from an arbitrary alert payload: `service ← payload.service|"unknown"`, `severity ← payload.severity|"P2"`, `description ← payload.description|payload.title|"Alert"`, `id ← payload.id|"webhook"`; response 200 `{ "status":"investigated", "summary":string }` (note: no `alert_id`).

**POST /chat** — request `{ message:string (required), sessionId:string (default ""), conversationId:string (default "") }`; response 200 `{ "message":string }`.

> The `summary`/`message` value is the LLM's final narrative (or the max-turns sentinel).

### 7.2 MCP Interface (proxy `POST /mcp` and backend `POST /mcp`)

JSON-RPC 2.0 over HTTP POST. Methods: `initialize`, `notifications/initialized`, `ping`, `tools/list`, `tools/call`. Protocol version `2024-11-05`. Success result envelope for tool calls: `{ content:[{ type:"text", text:<stringified JSON> }], isError:boolean }`. Error codes: `-32601` (method not found), `-32603` (tool/internal error). Tool catalog and schemas: §4.3.1 (proxy), §4.4/§4.5 (backends).

### 7.3 Mesh Service APIs

See §4.1.2 (business routes), §4.1.1 (chaos routes). Every service also exposes `GET /health`.

### 7.4 Message-Bus Interface

Subject `orders.created`; envelope `{ orderId:string, customerId:integer, total:decimal, traceparent:string }` (see ORD-5/ORD-6).

### 7.5 CLI Interfaces

- load-gen: `--pattern <baseline|spike|regression>` (or env `LOADGEN_PATTERN`).
- Operational convenience targets (see §12.5): stack up/down (mock and SaaS), chaos inject/reset, run tests, trigger investigation, MCP inspector.

---

## 8. Observability Requirements

### 8.1 Metrics

- **OB-1** Every service (mesh, proxy, agent) MUST expose a metrics scrape endpoint (port 9797) for collection.
- **OB-2** The collector MUST scrape those endpoints (this snapshot: 15s interval) and route metrics to the metrics backend only.
- **OB-3** The metrics backend MUST provide, at minimum, per-service error-rate and request-duration series and monitor state sufficient to fire an incident alert (e.g. payment-service error rate > 10%).

### 8.2 Logs

- **OB-4** Logs MUST be structured JSON. Every line MUST include `trace_id` and `span_id`; incident-relevant lines SHOULD also include domain fields (e.g. `order_id`, `customer_id`, `sku`, `qty`, `total`, `amount`, `currency`, `payment_id`, `auth_id`, `status`, `subject`) and an error field when applicable.
- **OB-5** Logs MUST route to the logs backend only.

### 8.3 Distributed Tracing

- **OB-6** All services MUST emit OTLP traces to the collector; traces MUST route to **both** backends to enable cross-system correlation.
- **OB-7** Trace-context MUST propagate automatically over HTTP and explicitly over the message bus (ORD-6). DB calls MUST appear as child spans.
- **OB-8** The collector MUST stamp resource attributes `service.namespace=devops-poc` and `deployment.environment=demo` on all telemetry, and SHOULD normalize service names so `<x>_service` becomes `<x>-service`.
- **OB-9** The agent MUST be self-observable: its reasoning spans, per-LLM-call latency, tool-call durations, and token usage MUST flow through the same collector.

### 8.4 Alerting

- **OB-10** A metrics monitor MUST be able to fire on the headline condition (payment-service error-rate threshold) and deliver a webhook to the agent's `POST /webhook/alert` within a target of ~60 seconds.

> **Implementation Note:** The collector defines a container-log file receiver that is not wired into any pipeline in this snapshot (a local-mount limitation); logs reach the logs backend via OTLP. A production/Linux deployment MAY enable the file receiver.

---

## 9. Security Requirements

- **SR-1** Chaos-control endpoints MUST require a shared token header (`X-Chaos-Token`) and MUST reject mismatches with HTTP 403. Chaos endpoints MUST be internal-network only.
- **SR-2** LLM and backend credentials MUST be supplied via configuration/secrets, never hardcoded, and MUST be absent from committed files.
- **SR-3** Remediation MUST be bounded to a fixed typed runbook allowlist; no generic execution surface may exist. A human approval gate MUST precede any mutating action (propose-before-act).
- **SR-4** When an AI gateway or MCP gateway fronts the agent/proxy, request bodies may capture bearer tokens; such tokens MUST be scrubbed/redacted before reaching a trace store.
- **SR-5** The design MUST separate read (diagnosis) from write (remediation) trust tiers; remediation SHOULD be isolatable behind its own gated surface.

> **Implementation Note:** In this snapshot the proxy's `/mcp` and `/health` and the mesh business endpoints are unauthenticated (trusted local network). Production requires OIDC/SSO for humans, workload identity for agents, a secrets manager, and a mandatory MCP gateway enforcing per-tool RBAC, rate-limiting, quota, and immutable audit tied to identity.

---

## 10. Non-Functional Requirements

### 10.1 Performance

- **NF-1** Agent reasoning SHOULD complete a full investigation within ~90 seconds for a live demo; hosted-LLM runs SHOULD complete in ~30–60s, local-model runs within ~1–3 minutes.
- **NF-2** The end-to-end incident cycle MUST target ~5 minutes.
- **NF-3** The collector MUST batch (this snapshot: batch size 1024, 5s timeout) and enforce a memory limiter (80% limit, 25% spike) to survive load.

### 10.2 Reliability & Resilience

- **NF-4** MCP federation and agent MCP initialization MUST be non-fatal on backend unavailability (retry / degrade).
- **NF-5** The async publish leg MUST be non-fatal to the order.
- **NF-6** Cache and message-bus unavailability MUST degrade gracefully to the authoritative store / warn-and-continue.

> **Implementation Note:** No retry/backoff is implemented in the agent's LLM or MCP calls in this snapshot — a failure surfaces as an error or a tool-error string fed back to the model. HTTP client timeouts: agent→proxy 30s; Anthropic/OpenAI/AMP 120s; Ollama chat 180s (readiness 10s, model pull 600s); proxy→backend 30s; health probe 3s; chaos-reset 5s; agent listener idle 600s.

### 10.3 Operational

- **NF-7** Health-checked components MUST expose a liveness endpoint suitable for container health checks.
- **NF-8** All services MUST honor configuration via environment variables with sensible defaults (see §12.1), so the creds-free mock stack runs with no `.env`.
- **NF-9** Services MUST restart automatically on failure under the orchestrator.

### 10.4 Configuration Management

- **NF-10** Environment variables MUST take precedence over file-based configuration where both exist. Empty-string values MUST be treated as unset (fall back to default).

---

## 11. Testing Requirements

- **TR-1** Each package MUST ship unit tests exercising pure functions and handler logic without external network dependencies where feasible.
- **TR-2** A test harness MUST bring up the stateful infrastructure (DB, cache, message bus), run all package unit tests with host overrides, aggregate pass/fail per package, and tear infrastructure down afterward.
- **TR-3** A credential-free integration test MUST validate the proxy federation and routing invariants: (a) `tools/list` returns only `discover_tools` + topology tools (lazy loading holds — no backend tools leak), (b) `discover_tools` reveals a backend tool manifest, (c) a namespaced backend tool call routes through the proxy to the mock and returns fixture data, (d) a topology tool dispatches locally (e.g. `list_runbooks` includes `disable-chaos`).
- **TR-4** End-to-end scenario tests MUST cover: the headline payment-service 502 incident (agent invokes ≥1 tool per domain, proposes `disable-chaos`, returns a summary with trace id + involved services + evidence links); a slow-query regression (DB-bound vs network-bound diagnosis from span breakdowns); an async backlog (message-bus backlog identification).
- **TR-5** Chaos/fault-injection capability MUST be testable via the chaos contract (latency, error-rate, reset) and the recovery runbook.

> **Implementation Note:** This snapshot has ~152 test functions across 12 packages (mesh subset = 80). Package counts observed: store 9, customer 9, order 9, inventory 8, invoice 10, payment 9, notification 12, load-gen 14, agent 12, mcp-proxy 41, logs-mock 8, metrics-mock 11. (Some docs cite a stale "129" / "22 proxy" baseline.)

---

## 12. Deployment & Infrastructure Requirements

### 12.1 Environment Variable Catalog

**Shared telemetry (all services):**

| Var | Purpose | Default | Req? |
|---|---|---|---|
| OTEL_EXPORTER_OTLP_ENDPOINT | OTLP gRPC target | http://otel-collector:4317 | optional |
| OTEL_RESOURCE_ATTRIBUTES | Resource tags | service.namespace=devops-poc,deployment.environment=demo,git.commit=${GIT_COMMIT} | optional |
| OTEL_SERVICE_NAME | Service identity | `<svc>-service` | optional |
| CHAOS_TOKEN | Chaos endpoint token | dev-chaos-token | optional |
| GIT_COMMIT | Stamped into traces | unknown | optional |

**Database (store/customer/order/inventory/invoice):**

| Var | Purpose | Default | Req? |
|---|---|---|---|
| DB_HOST | DB host | postgres | optional |
| DB_PORT | DB port | 5432 | optional |
| DB_USER | DB user | poc | optional |
| DB_PASSWORD | DB password | pocpass | optional |
| DB_NAME | Per-service DB | storedb/customerdb/orderdb/inventorydb/invoicedb | optional |

**Service wiring:**

| Var | Component | Default | Req? |
|---|---|---|---|
| INVENTORY_URL | store, order, load-gen | http://inventory:9090 | optional |
| CUSTOMER_URL | order, load-gen | http://customer:9090 | optional |
| PAYMENT_URL | order | http://payment:9090 | optional |
| INVOICE_URL | order, load-gen | http://invoice:9090 | optional |
| STORE_URL / ORDER_URL | load-gen | http://store:9090 / http://order:9090 | optional |
| NATS_URL | order, notification | nats://nats:4222 | optional |
| REDIS_HOST / REDIS_PORT | inventory | redis / 6379 | optional |
| LOADGEN_PATTERN | load-gen | baseline | optional |

**Proxy:**

| Var | Purpose | Default | Req? |
|---|---|---|---|
| SPLUNK_MCP_URL | Logs backend URL | http://splunk-mock-mcp:8400 | optional |
| DATADOG_MCP_URL | Metrics backend URL | http://datadog-mock-mcp:8401 | optional |
| DD_SITE | Metrics site for trace deep-link | datadoghq.com | optional |
| SPLUNK_URL | Logs web base for search deep-link | https://your-splunk.splunkcloud.com | optional |
| CHAOS_TOKEN | Token for disable-chaos runbook | dev-chaos-token | optional |
| REDIS_HOST | Host string in clear-cache step text | redis | optional |

**Agent:**

| Var | Purpose | Default | Req? |
|---|---|---|---|
| LLM_PROVIDER | Provider selector | ollama (stack) / anthropic (code) | optional |
| ANTHROPIC_API_KEY | Anthropic auth | (none) | req if provider=anthropic |
| ANTHROPIC_URL | Anthropic base / gateway | https://api.anthropic.com | optional (gateway-injected) |
| AGENT_MODEL | Anthropic model | claude-sonnet-4-6 | optional |
| OLLAMA_BASE_URL / OLLAMA_MODEL | Ollama endpoint/model | http://host.docker.internal:11434 / qwen3.5:9b | optional |
| OPENAI_API_KEY / OPENAI_BASE_URL / OPENAI_MODEL | OpenAI auth/endpoint/model | (none) / https://api.openai.com / gpt-4o | key req if provider=openai |
| LLM_BASE_URL / LLM_API_KEY / LLM_MODEL | AMP gateway base/auth/model | (none) / (none) / gpt-4o | base req if provider=amp |
| BALLERINA_TOPOLOGY_MCP_URL | Single MCP entry point | http://mcp-proxy:8290 | optional |
| CSV_MCP_PROXY / CSV_MCP_PROXY_PATH | Optional token-usage CSV | FALSE / ollama_tokens_mcp_proxy.csv | optional |

**Live-backend / infra (SaaS profile):**

| Var | Purpose | Default | Req? |
|---|---|---|---|
| DD_API_KEY | Metrics exporter/agent key | (none) | req in SaaS mode |
| DD_APP_KEY | Metrics vendor application key (future MCP/API) | (none) | optional |
| DD_SITE | Metrics site | datadoghq.com | optional |
| DD_APM_ENABLED / DD_APM_NON_LOCAL_TRAFFIC | Metrics agent APM intake | true / true | — |
| DD_LOGS_ENABLED | Disable logs at metrics vendor | false | — |
| SPLUNK_HEC_URL / SPLUNK_HEC_TOKEN / SPLUNK_INDEX | Logs HTTP event collector | (none) / (none) / main | req in SaaS mode |
| POSTGRES_USER / POSTGRES_PASSWORD | DB superuser | poc / pocpass | optional |

### 12.2 Port Map

See §4.0. OTLP 4317 (gRPC) / 4318 (HTTP); DB 5432; cache 6379; bus 4222 (client) + 8222 (monitoring); metrics scrape 9797; optional local trace UI 16686.

### 12.3 Telemetry Collector Pipeline

- **DP-1** Receivers MUST include OTLP (gRPC + HTTP) and a metrics scrape receiver.
- **DP-2** Processors MUST include a memory limiter, a batch processor, a resource processor (upserting the two resource attributes), and a service-name normalizer (`_service$` → `-service`, on traces and metrics).
- **DP-3** Pipelines MUST route: **traces** → both backends; **metrics** → metrics backend only; **logs** → logs backend only. In credential-free mode a debug exporter stands in for the live exporters.

### 12.4 Startup Ordering

- **DP-4** Startup MUST honor: infra roots (DB, cache, bus, collector) first; leaf mesh services after their infra is healthy; order-service after its four synchronous dependencies + bus; load-gen after all front-doors; mock backends before the proxy; the proxy before the agent.
- **DP-5** Stateful infra (DB, cache, bus) and the proxy and agent MUST expose health checks used for readiness gating.

### 12.5 Dev vs Production Configuration

- **DP-6** The default stack MUST be credential-free: mock backends, debug telemetry exporter, local-LLM default.
- **DP-7** A SaaS mode MUST enable live telemetry exporters (both vendors) and MAY add a metrics-vendor agent sidecar, selected purely by configuration + a compose override — no source change.
- **DP-8** A clean-machine bring-up (`down -v && up`) MUST succeed in under ~5 minutes.

### 12.6 Runtime

- **DP-9** All components MUST be containerized. Container health probes MUST use a tool present in the runtime image. Build artifacts MUST be isolated from any base-image volume path to avoid stale-artifact shadowing.

---

## 13. Developer Experience Requirements

- **DX-1** Unit tests MUST be runnable without containers or credentials for pure-function packages; the full unit suite MUST be runnable via a single command that provisions infra automatically.
- **DX-2** A single command MUST bring up the full mock stack; another MUST tear it down; another MUST run a full rehearsal (up → inject chaos → investigate → reset).
- **DX-3** Fault injection and reset MUST be scriptable one-liners targeting a service by name with default parameters.
- **DX-4** The MCP Proxy MUST be inspectable with a standard MCP inspector over Streamable HTTP at `/mcp`.
- **DX-5** Switching LLM provider or mock↔live backend MUST be a configuration edit only.
- **DX-6** A new engineer MUST be able to stand up the stack and run the rehearsal within about an hour using the provided phase docs.

> **Implementation Note:** Builds are sequential to avoid parallel-build memory exhaustion. The MCP inspector MUST be connected using `127.0.0.1` (not `localhost`) and the Streamable HTTP transport.

---

## 14. Glossary

| Term | Definition |
|---|---|
| **MCP** | Model Context Protocol — the tool-invocation contract between the agent and its tool servers; here JSON-RPC 2.0 over HTTP POST to `/mcp`. |
| **MCP Proxy** | The single MCP entry point the agent connects to; owns local topology/correlation/runbook tools and federates the logs/metrics backends. |
| **Streamable HTTP** | The MCP transport used here: one-shot JSON-RPC request/response over HTTP POST (no stdio). |
| **Federation** | The proxy connecting to backend MCP servers as a client and re-exposing their namespaced tools. |
| **Namespace prefix** | `topology__` / `splunk__` / `datadog__` prefixes on tool names; the proxy routes by stripping the prefix at the `__` separator. |
| **Lazy tool loading** | Advertising only a small tool set (discover_tools + topology) up front and revealing backend tools on demand via `discover_tools`, to keep the LLM context small. |
| **discover_tools** | The proxy tool that scores registered tool manifests against a query and returns the top matches. |
| **Propose-before-act** | The hard guardrail requiring the agent to list runbooks and obtain human approval before executing any mutating runbook. |
| **Runbook** | A fixed, typed, vetted remediation action (the only mutating capability); e.g. `disable-chaos`. |
| **Chaos** | Injected fault (latency and/or error-rate) used to manufacture the demo incident; controlled via token-gated `/chaos/*` endpoints on a separate listener. |
| **correlate_trace** | The proxy tool that returns cross-system links (metrics deep-link + logs SPL/URL) and involved services for a trace id — links and topology only. |
| **Join key** | The `trace_id`/`span_id` present in structured logs, used to match a trace in the metrics backend to log lines in the logs backend. |
| **traceparent** | The W3C trace-context string (`00-<traceId>-<spanId>-01`) explicitly injected into the async message envelope. |
| **Blast radius** | The set of upstream/downstream services impacted by an incident, computed from the dependency graph. |
| **Front-facing domains** | The five services (store, customer, inventory, invoice, order) driven directly by the traffic generator. |
| **Headline incident** | The demo scenario: payment-service returns ~30% 502s + 2s latency; the agent diagnoses and proposes `disable-chaos`. |
| **Fan-out (telemetry)** | Traces → both backends; logs → logs backend; metrics → metrics backend. |
| **DB-per-service** | One logical database per stateful service to prevent cross-service telemetry contamination. |
| **SLA** | Declared service availability target in the catalog. |
| **Deploy freeze** | An in-memory flag set by the `freeze-deploys` runbook, read via `get_deploy_freeze_status`. |
| **LLM provider** | The interchangeable model backend selected by `LLM_PROVIDER` (ollama / anthropic / openai / amp). |
| **AMP** | An OpenAI-compatible AI gateway that injects the base URL and may handle auth, enabling model routing/audit/quotas without agent changes. |
