# DevOps OverSight Agent POC

A local-first demo: a Ballerina retail microservice mesh emits traces, logs, and metrics through a single OTel Collector to **Splunk** (logs/traces) and **Datadog** (APM/metrics). A ballerina agent running under **WSO2 Agent Manager** correlates those signals over MCP to diagnose and remediate a chaos-induced incident.

## Contents

- [Demo Steps (5 minutes)](#demo-steps-5-minutes)
- [Usage](#usage)
- [Repository layout](#repository-layout)
- [Service mesh (7 services + load-gen)](#service-mesh-7-services--load-gen)
- [Getting started](#getting-started)
- [Architecture at a glance](#architecture-at-a-glance)
- [MCP best practices](#mcp-best-practices)
- [Services](#services)
- [Observability pipeline](#observability-pipeline)
- [MCP servers](#mcp-servers)
- [Agent (client)](#agent-client)
- [See also](#see-also)

## Demo Steps (5 minutes)

**Prerequisite:** Ollama running on your Mac with a tool-capable model. (Tested with `qwen3.5:9b`; other Qwen models work.)

```bash
# 1. Start the compose stack (Phase 1 + Phase 2 mesh)
make demo-mock-up

# Verify health (expect {"status":"UP",...} from each)
for p in 8092 8290 8400 8401; do echo -n "$p: "; curl -s http://localhost:$p/health; echo; done

# 2. Inject chaos into payment-service (0:00–0:45)
make inject-chaos
# Shows: latency injected + error rate injected

# 3. Run the investigation (1:15–4:45)
# The agent queries MCPs, runs the Ollama tool loop, and proposes `disable-chaos`
make investigate
# Expect: HTTP 200, full markdown diagnosis with findings + analysis + proposal
# Takes ~1–3 min on qwen3.5:9b (local model runtime)

# 4. Reset chaos (simulates approval + remediation) (4:45–5:00)
make reset-chaos
# All 7 services return "reset OK"

# Demo complete. Mesh recovers within 30s. Full end-to-end: ~5 min.
```
**If Ollama is not reachable:** set `LLM_PROVIDER=anthropic` + `ANTHROPIC_API_KEY=sk-ant-api03-…` in `compose/.env`, or `LLM_PROVIDER=openai` + `OPENAI_API_KEY=sk-…`. Anthropic/OpenAI runs are faster (~30–60 s vs 1–3 min for local Ollama). See the [LLM provider reference](#trigger-a-live-agent-investigation) for the full table.

**Full rehearsal (all steps + startup):**
```bash
make rehearse
```

**Manual Demo:**
See [manualdemo.md](demo/manualdemo.md)

---

## Usage

### Unit tests — no Docker, no keys needed

```
  make test-bal
  This runs bal test across all 12 packages. You'll see pass/fail per package. Expected: 129 total passing.

  Individual packages:
  cd code/mcp/mcp-proxy && bal test        # 22 tests
  cd code/mcp/splunk-mock-mcp && bal test   # 8 tests
  cd code/mcp/datadog-mock-mcp && bal test  # 11 tests
  cd code/agent && bal test             # 8 tests
```

  ---
### Run the full stack (mock mode — no Splunk/Datadog/Anthropic creds needed for health checks)

```
  make demo-mock-up
  Then verify all four new services are up:
  curl http://localhost:8092/health   # devops-oversight-agent (host 8082 collides with Colima's AMP VM forward)
  curl http://localhost:8290/health   # mcp-proxy
  curl http://localhost:8400/health   # splunk-mock-mcp
  curl http://localhost:8401/health   # datadog-mock-mcp
```

  ---
### Inspect the MCP Proxy tools interactively

The MCP Proxy speaks **Streamable HTTP** (plain HTTP POST at `/mcp`) — not STDIO. The inspector must be told that explicitly; passing the URL as a positional arg to the CLI causes `spawn … ENOENT`.

**Step-by-step:**

1. Make sure `mcp-proxy` is running (`curl http://localhost:8290/health` → `{"status":"UP"}`).

2. Start the inspector:
   ```
   make mcp-inspect
   ```
   The terminal will print something like:
   ```
   ⚙️  Proxy server listening on 127.0.0.1:6277
   🔗 Open inspector with token pre-filled:
      http://localhost:6274/?MCP_PROXY_AUTH_TOKEN=<token>
   ```

3. **Open that URL in your browser** (the token is already in the URL — just click it or paste it).

4. In the browser UI, locate the connection panel at the top:
   - **Transport** dropdown → select **`Streamable HTTP`**
   - **URL** field → enter `http://127.0.0.1:8290/mcp`
   - Click **Connect**

   You should see `Connected` in green and the server info pane populate.

5. Click the **Tools** tab → **List Tools**. You'll see `discover_tools` plus the 11 `topology__*` tools: `topology__lookup_service`, `topology__get_dependencies`, `topology__list_services`, `topology__get_service_health`, `topology__correlate_trace`, `topology__find_recent_deploys`, `topology__find_related_incidents`, `topology__list_runbooks`, `topology__run_runbook`, `topology__get_audit_log`, `topology__get_deploy_freeze_status`. Splunk/Datadog tools are **not** in this list — they are hidden server-side until you call `discover_tools`.

6. **Call a tool manually** — click any tool, fill in the inputs, click **Run Tool**:
   - `topology__list_services` — no inputs — returns all 7 mesh services
   - `topology__lookup_service` → `name: payment-service` — returns owner, deps, runbooks, SLA
   - `topology__get_dependencies` → `name: order-service`, `direction: downstream` — returns dependency graph
   - `topology__correlate_trace` → `trace_id: abc123` — returns Datadog + Splunk URLs for a trace

7. Press `Ctrl-C` in the terminal to stop the inspector proxy when you're done.

  ---
### Trigger a live agent investigation

The agent's LLM backend is controlled by `LLM_PROVIDER` in `compose/.env`. The same image runs locally and in AMP — switching is purely env-var-driven, no code changes.

**Running locally (`make rehearse` / standalone):**

| Want | `compose/.env` |
|---|---|
| Creds-free (default) | `LLM_PROVIDER=ollama` (needs Ollama on host with a tool-capable model, e.g. `qwen3.5:9b`) |
| Anthropic direct | `LLM_PROVIDER=anthropic` + `ANTHROPIC_API_KEY=sk-ant-api03-…` (`sk-ant-oat01-` OAuth tokens do NOT work for direct calls) |
| OpenAI direct | `LLM_PROVIDER=openai` + `OPENAI_API_KEY=sk-…` (optionally `OPENAI_BASE_URL` for a compatible endpoint, `OPENAI_MODEL`) |

**Deployed into AMP — no `.env` changes needed:**

| AMP LLM config | What to set | How it works |
|---|---|---|
| AMP routes to Anthropic | `LLM_PROVIDER=anthropic` as a component env var | AMP automatically injects `ANTHROPIC_URL` pointing at its AI gateway; `anthropic_client.bal` reads it with `envOr("ANTHROPIC_URL", "https://api.anthropic.com")` — the redirect is seamless |
| AMP routes to any other model (GPT-4o, Llama, etc.) | `LLM_PROVIDER=amp` as a component env var, `LLM_MODEL=<model>` | AMP injects `LLM_BASE_URL` for its OpenAI-compatible gateway; `llm_client.bal` picks it up and routes to `runOpenAICompatLoop`; `LLM_API_KEY` is optional (AMP may handle auth at the gateway) |

> **Key invariant:** `ANTHROPIC_URL` and `LLM_BASE_URL` are never set in your local `.env` or compose file — they're absent locally (code falls back to the real public endpoints) and only appear when AMP deploys the component. You never edit the image or the code to switch environments.

```bash
# Ollama (default): just have Ollama up with a tool-capable model, then:
make investigate
# The agent calls mcp-proxy (which routes to Splunk/Datadog MCPs), runs the
# tool-use loop, and returns a JSON summary with its diagnosis + a proposed
# runbook (it stops for approval before acting).
# Local-model runs take ~1–3 min; Anthropic/OpenAI is faster (~30–60 s). Agent is on host port 8092.
```

  ---
###  Teardown

```
  make demo-down
```

## Repository layout

| Path | Contents |
|------|----------|
| [`README.md`](README.md) · [`architecture.md`](architecture/architecture.md) · [`CLAUDE.md`](CLAUDE.md) | This file (component reference); deep-dive architecture; Claude Code guidance + locked decisions |
| `todo/` | Authoritative phase specs (`phase-0` … `phase-5`) — start with [`todo/README.md`](todo/README.md) |
| `code/` | Ballerina source — `agent/` (DevOps agent), `mcp/` (MCP Proxy + 2 mock MCPs), `generate/` (7 mesh services + `load-gen`) |
| `compose/` | Docker Compose observability stack (Phase 1) |
| `demo/` | Demo script + chaos inject/reset scripts (Phase 5) |

## Service mesh (7 services + load-gen)

`store` · `customer` · `order` · `inventory` · `invoice` · `payment` · `notification`, driven by `load-gen`. See [`CLAUDE.md`](CLAUDE.md) for the architecture diagram and [`todo/phase-2-ballerina.md`](todo/phase-2-ballerina.md) for the mesh topology.

## Getting started

This POC is built phase-by-phase. See [`todo/README.md`](todo/README.md) for the phased plan and per-phase exit criteria.

---

## Architecture at a glance

The system has two tiers. A **workload tier** (Docker Compose) runs the seven-service Ballerina retail mesh plus the infrastructure it depends on (Postgres, Redis, NATS) and the telemetry pipeline (a single OTel Collector fanning out to Splunk and Datadog). 

An **agent tier** (WSO2 Agent Manager on Kubernetes/kind) runs a **Ballerina** incident-response agent that reaches a **single MCP Proxy** (`:8290`). The proxy federates the Splunk and Datadog MCP backends itself — the agent never connects to them directly.

For the deep dive — full topology diagrams, the telemetry fan-out, the trace-correlation flow, and the propose-before-act remediation loop — see **[`architecture.md`](architecture/architecture.md)**. This README is the component reference and getting-started; it does not duplicate those diagrams.

## MCP best practices

The agent reaches every observability backend through **one MCP entry point — the MCP Proxy** (`mcp-proxy`, `:8290`, source in `code/mcp/mcp-proxy/`). The proxy owns the topology, correlation, and runbook tools locally, federates the Splunk/Datadog MCP backends (connecting to them itself), and routes each namespaced tool call to the right origin by stripping its prefix. This federated-proxy shape is deliberate: it keeps the agent's context small, makes mock↔live a one-env-var swap on the proxy (never the agent), and gives a single place to apply routing, result, and guardrail policy. Lazy loading lives in the proxy too — it advertises only `discover_tools` + the topology tools in `tools/list`, keeps the Splunk/Datadog manifests in a server-side registry, and returns them on demand when the agent calls `discover_tools`. The agent seeds its context from the proxy's tool list and folds discovered manifests in as the investigation proceeds. See the flow diagrams in **[`architecture/sequence-overview.md`](architecture/sequence-overview.md)** (agent → proxy → backends) and **[`architecture/sequence-tool-routing.md`](architecture/sequence-tool-routing.md)** (registry lookup + prefix routing inside the proxy).

The full pattern catalog and rationale live in the **[`mcp best practices/`](mcp%20best%20practices/)** folder:

- **[`mcp-low-context-how-to.md`](mcp%20best%20practices/mcp-low-context-how-to.md)** — the engineering reference: eight patterns + safety notes, each with problem / solution / implementation / tradeoffs.
- **[`mcp-low-context-slides.html`](mcp%20best%20practices/mcp-low-context-slides.html)** — the slide deck version.

How this demo maps to each practice:

| # | Practice | What it is | In demo? | Comment |
|---|---|---|:--:|---|
| 1 | Minimal surface / split servers | Break large servers into ≤4 semantic units per component | **Y** | 3 servers; the proxy's 11 tools split cleanly into topology / correlation / runbook |
| 2 | Lazy tool loading / deferred discovery | Expose a `discover_tools` gateway; don't inject all manifests upfront | **Y** | Topology pre-seeded; Splunk/Datadog loaded on demand |
| 3 | Semantic router / tool registry | Back discovery with pgvector + embeddings for top-k matching | **Partial** | The registry + `discover_tools` search live in the proxy (Pattern 3's shape), but a keyword scorer stands in for pgvector — accurate enough for ~21 tools; vector infra is deferred until live vendor MCPs (50+ tools each) land |
| 4 | Higher-level abstractions | Replace fine-grained tool clusters with Skills / CLI bridges / subagents | **Y** | `correlate_trace` bundles DD URL + Splunk SPL + involved services in one call; runbooks wrap multi-step actions |
| 5 | Per-session tool sets / project scoping | Multiple `mcp.*.json` configs selected per project | **N** | Does not apply — single-purpose agent with a fixed toolset, not a multi-project Claude config |
| 6 | Namespace + router-friendly descriptions | Prefix federated tool names; write domain-tagged descriptions | **Y** | `splunk__`/`datadog__`/`topology__` name prefixes; `[splunk]`/`[correlation]`/`[runbook]` description tags |
| 7 | Tool-result hygiene | Bound (truncate/summarize) and neutralize results before they re-enter the loop | **N** | Not a POC priority — mock MCPs return small, trusted payloads; required before pointing at live Splunk/Datadog, where queries return large, attacker-influenced text |
| 8 | Propose-before-act (HITL) | Human approval before any mutating tool call | **Y** | Hard guardrail: the agent must `list_runbooks` and get explicit approval before `run_runbook` |
| 9 | Auth / least-privilege on the endpoint | Bearer token or gateway in front of mutating tools | **N** | Doesn't fit a POC — the proxy runs on a trusted local Docker network; production defers auth to the WSO2 MCP Gateway |
| 10 | CLI / execute gateway least-privilege | Allowlist + low-priv service account for any `run_cli` tool | **N/A** | No `run_cli`/execute tool is exposed — runbooks are a fixed, typed allowlist |
| 11 | Code-mode sandbox choice | Prefer quickjs-emscripten over RestrictedPython | **N/A** | No code-mode executor in this design |

## Services

Every service is a Ballerina package under `code/generate/<dir>/` (mesh) or `code/agent/`, `code/mcp/<server>/`; its OTel service name is `<dir>-service`. Every service exposes its business routes plus `GET /health` (probed by the Ballerina MCP) and a token-gated, internal-only `POST /chaos/latency | /chaos/error | /chaos/reset` lever set used by the Phase 5 demo to inject and clear the incident.

| Service | Dir | Role | Talks to | Infra | Chaos modes |
|---|---|---|---|---|---|
| `store-service` | `code/generate/store/` | Storefront / catalog browse | `inventory`, Postgres | Postgres | latency, 500 |
| `customer-service` | `code/generate/customer/` | Customer profiles / accounts | Postgres | Postgres | latency, 500 |
| `order-service` | `code/generate/order/` | Front-door `POST /orders` orchestrator | `customer`, `inventory`, `payment`, `invoice`; NATS → `notification` | Postgres | DB slow query, 500 on validation |
| `inventory-service` | `code/generate/inventory/` | Reserves stock | Redis, then Postgres on miss | Redis + Postgres | cold-cache latency spike |
| `invoice-service` | `code/generate/invoice/` | Generates invoice / billing record | Postgres | Postgres | latency, 500 |
| `payment-service` | `code/generate/payment/` | Charges card (mocked) | in-process `mock-bank` (dummy) | — | timeout, sporadic 502 (**headline demo**) |
| `notification-service` | `code/generate/notification/` | Sends order confirmation | NATS subscriber (async) | NATS | slow consumer / backlog |
| `load-gen` | `code/generate/load-gen/` | Traffic generator (driver, not a service) | all front-door services | — | n/a — it's the driver |

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
- **Source:** `code/generate/store/`.

### customer-service

- **Purpose:** customer profiles and accounts (signup / lookup).
- **Endpoints:** profile/account routes; `GET /health`; `POST /chaos/{latency,error,reset}`.
- **Dependencies:** Postgres (its own schema). No downstream service calls.
- **Infra:** Postgres.
- **Failure / chaos modes:** injected latency, HTTP 500.
- **Source:** `code/generate/customer/`.

### order-service

- **Purpose:** the front-door orchestrator — `POST /orders` fans out across the mesh and is the entry point for the headline trace.
- **Endpoints:** `POST /orders` (orchestration); `GET /health`; `POST /chaos/{latency,error,reset}`.
- **Dependencies:** synchronous HTTP to `customer` (validate), `inventory` (reserve), `payment` (charge), `invoice` (bill); then publishes an order event to **NATS → `notification`** (async confirm). Persists to Postgres (its own schema).
- **Infra:** Postgres; NATS (publisher).
- **Failure / chaos modes:** DB slow query, HTTP 500 on validation.
- **Note:** the `order → notification` NATS hop must carry explicit OTel trace context in the message envelope so the async leg stays part of one connected trace (HTTP propagation is automatic; NATS is not).
- **Source:** `code/generate/order/`.

### inventory-service

- **Purpose:** reserves stock; the cold-cache latency story.
- **Endpoints:** stock check / reserve routes; `GET /health`; `POST /chaos/{latency,error,reset}`.
- **Dependencies:** reads Redis first, falls back to Postgres on a cache miss.
- **Infra:** Redis (cache) + Postgres. Its Redis cache is the target of the `clear-cache` runbook (`FLUSHDB`).
- **Failure / chaos modes:** cold-cache latency spike (cache miss → backend latency).
- **Source:** `code/generate/inventory/`.

### invoice-service

- **Purpose:** generates the invoice / billing record for an order.
- **Endpoints:** invoice generate / query / pay routes; `GET /health`; `POST /chaos/{latency,error,reset}`.
- **Dependencies:** Postgres (its own schema).
- **Infra:** Postgres.
- **Failure / chaos modes:** injected latency, HTTP 500.
- **Source:** `code/generate/invoice/`.

### payment-service

- **Purpose:** charges the card (mocked) against an **in-process `mock-bank`** that returns a dummy response — no real external call. **This is the headline demo chaos target.**
- **Endpoints:** charge route; `GET /health`; `POST /chaos/{latency,error,reset}`.
- **Dependencies:** none external — the `mock-bank` is simulated in-process. No database of its own.
- **Infra:** none.
- **Failure / chaos modes:** timeout, sporadic 502 — the demo injects ~30% 502 + 2s latency here to start the incident.
- **Source:** `code/generate/payment/`.

### notification-service

- **Purpose:** sends order confirmation; the async consumer leg of the mesh.
- **Endpoints:** internal/health routes; `GET /health`; `POST /chaos/{latency,error,reset}`. (Driven asynchronously, not by the load-gen directly.)
- **Dependencies:** NATS subscriber — consumes order events published by `order-service`.
- **Infra:** NATS.
- **Failure / chaos modes:** slow consumer / backlog (drives the async-backlog diagnosis scenario).
- **Source:** `code/generate/notification/`.

### load-gen

- **Purpose:** the traffic generator — a long-lived Ballerina worker (not a service) that keeps the mesh busy so the observability stack has something to show.
- **What it drives:** the five front-facing domains — `customer` (signup/lookup), `order` (`POST /orders` with varied SKUs + customer IDs), `invoice` (query/pay), `inventory` (stock check), `store` (catalog browse). `payment` and `notification` are exercised transitively through `order`.
- **Config:** reads YAML pattern files — `baseline.yaml`, `spike.yaml`, `regression.yaml` — plus per-domain flow definitions; selects one via the `--pattern baseline|spike|regression` CLI arg. Runs as a long-lived compose container defaulting to `baseline`.
- **Telemetry:** emits its own OTel spans so the generated load itself is visible in Datadog.
- **Source:** `code/generate/load-gen/`.

## Observability pipeline

All services emit OTLP natively (Ballerina observability module) to a **single OTel Collector** (OTLP gRPC `:4317` / HTTP `:4318`), which fans out by signal type:

| Signal | Destination | Why |
|---|---|---|
| Traces | **Datadog (APM) + Splunk (HEC)** | both ends of the correlation join |
| Logs | **Splunk (HEC)** | Splunk is the log-of-record (`DD_LOGS_ENABLED=false` to avoid double-billing) |
| Metrics | **Datadog** | Datadog is the metrics-of-record |

The Collector tags everything with `service.namespace=devops-poc` and `deployment.environment=demo`. The **join key** across systems is the structured-log `trace_id` / `span_id`: each service emits JSON logs carrying the active `trace_id` and `span_id`, so a trace seen in Datadog APM can be matched to its log lines in Splunk. Mind the trace-ID format mismatch — Datadog surfaces a 64-bit `dd.trace_id` alongside the 128-bit `otel.trace_id`; the Ballerina MCP correlation layer must handle both. See [`architecture.md`](architecture/architecture.md) for the full pipeline diagram and [`todo/phase-1-compose.md`](todo/phase-1-compose.md) for the Collector config.

## MCP servers

The agent has a **single MCP entry point: the MCP Proxy** (`mcp-proxy`, `:8290`). The proxy owns the service topology, correlation, and runbook tools locally, and routes Splunk/Datadog tool calls to the respective MCP backends. This keeps the agent's context small and makes switching between mocks and live SaaS endpoints a one-env-var change on the proxy, not the agent.

```
                        ┌─────────────────────────────────────────┐
                        │       DevOps Oversight Agent :8000       │
                        │       POST /chat · POST /investigate     │
                        └─────────────────────┬───────────────────┘
                                              │
                                    BALLERINA_TOPOLOGY_MCP_URL
                                              │
                                              ▼
                             ┌────────────────────────────┐
                             │        MCP Proxy :8290      │
                             │   code/mcp/mcp-proxy/      │
                             │                             │
                             │  topology · correlation     │
                             │  runbook executor           │
                             │  service catalog            │
                             └──────────┬──────────────────┘
                                        │
                          SPLUNK_MCP_URL │ DATADOG_MCP_URL
                                        │
               ┌────────────────────────┴──────────────────────┐
               │                                               │
               ▼                                               ▼
  ┌──────────────────────┐                      ┌──────────────────────┐
  │     Splunk MCP       │                      │    Datadog MCP       │
  │     (official)       │                      │    (official)        │
  │                      │                      │                      │
  │  dev  → :8400 mock   │                      │  dev  → :8401 mock   │
  │  prod → Splunk Cloud │                      │  prod → mcp.dd.com   │
  │                      │                      │                      │
  │  log search via SPL  │                      │  APM · metrics       │
  │  indexes · know objs │                      │  traces · monitors   │
  └──────────┬───────────┘                      └──────────┬───────────┘
             │                                             │
             ▼                                             ▼
       Splunk Cloud                                  Datadog Cloud
       (logs/traces)                                 (APM/metrics)
```

### Splunk MCP (official)

- **Server:** the official *MCP Server for Splunk platform* (Splunkbase app 7931, "Splunk Supported") — installed on your **Splunk Cloud** deployment, not run locally. Streamable HTTP at the app-generated HTTPS endpoint; auth via an MCP bearer token minted in the app (RBAC capability `mcp_tool_execute`).
- **Role / tools:** log search via SPL — `splunk_run_query` (e.g. `index=* trace_id="<id>"`), plus `splunk_get_indexes`, `splunk_get_knowledge_objects`. There's no per-trace tool — trace lookups are just SPL.
- **Wiring:** the MCP Proxy connects via `SPLUNK_MCP_URL`; `splunk-mock-mcp` (`:8400`) is the default until live creds arrive. Splunk Cloud trial receives telemetry via the Collector's `splunk_hec` exporter.

### Datadog MCP (official)

- **Server:** the official *Datadog MCP Server* (Bits AI) — **remote-hosted** by Datadog at `https://mcp.datadoghq.com/api/unstable/mcp-server/mcp` (regional per `DD_SITE`; in Preview, under `/api/unstable/` — pin it). Streamable HTTP; auth via OAuth 2.0 or `DD_API_KEY` + `DD_APPLICATION_KEY` headers. Toolsets selected via `?toolsets=apm,...`.
- **Role / tools (real names):** metrics — `get_datadog_metric`, `search_datadog_metrics`; errors — `search_datadog_error_tracking_issues`; APM traces — `get_datadog_trace` (full trace by ID), `apm_search_spans`; logs — `search_datadog_logs`; monitors — `search_datadog_monitors`. (Our earlier `get_service_metrics` / `get_service_errors` were placeholder guesses — these are the actual tools.)
- **Wiring:** the MCP Proxy connects via `DATADOG_MCP_URL`; `datadog-mock-mcp` (`:8401`) is the default until live creds arrive.

### MCP Proxy (custom)

The **single MCP entry point for the agent.** It owns the service catalog, dependency graph, cross-system correlation, and scoped runbook execution locally, and proxies Splunk/Datadog tool calls to the respective MCP backends. Built in Ballerina; runs over **Streamable HTTP on `:8290`** (HTTP/SSE fallback). Source lives in `code/mcp/mcp-proxy/`; the agent connects via `BALLERINA_TOPOLOGY_MCP_URL`. OTel-instrumented so its outbound calls show up in Datadog alongside the mesh. See [`todo/phase-3-mcp.md`](todo/phase-3-mcp.md).

**Tool catalog** (names as seen by the agent — `topology__*` are pre-seeded in `tools/list`; `splunk__*`/`datadog__*` are revealed on demand via `discover_tools`):

| Group | Tool (as called by the agent) | Inputs | Returns |
|---|---|---|---|
| Discovery | `discover_tools` | `query` | JSON manifest bundle of top-k tools matching the query (revealed Splunk/Datadog schemas are added to the agent's active tool set) |
| Lookup / topology | `topology__lookup_service` | `name` | `{ owner, repo, runbook_ids, sla, health_endpoint, dependencies }` |
| Lookup / topology | `topology__get_dependencies` | `name`, `direction` (`upstream`/`downstream`/`both`) | adjacency list (matches the Phase 2 topology) |
| Lookup / topology | `topology__list_services` | (none) | all known services with `last_seen` |
| Lookup / topology | `topology__get_service_health` | `name` | live `/health` probe — status + latency |
| Correlation | `topology__correlate_trace` | `trace_id` | Datadog APM URL + Splunk search URL/SPL + involved services — **links + topology only**; agent fetches live data via Splunk/Datadog tools |
| Correlation | `topology__find_recent_deploys` | `service`, `lookback` | recent deploys from a stub deploy log ("did something change?") |
| Correlation | `topology__find_related_incidents` | `service`, `lookback` | past incidents from a local SQLite stub (learning-from-history) |
| Runbooks | `topology__list_runbooks` | (none) | array of `{ id, name, description, params_schema }` |
| Runbooks | `topology__run_runbook` | `id`, `params` | streaming (SSE) progress of the execution |
| Ops | `topology__get_audit_log` | (none) | recent runbook execution audit entries |
| Ops | `topology__get_deploy_freeze_status` | (none) | current deploy-freeze flag state |

**Runbooks shipped:**

| ID | Action |
|---|---|
| `restart-service` | restart a container / pod via the Docker/K8s API |
| `clear-cache` | Redis `FLUSHDB` on `inventory-service`'s cache |
| `disable-chaos` | call `POST /chaos/reset` on a target service (the demo's recovery lever) |
| `freeze-deploys` | set a flag in a stub deploy registry |

**Service catalog:** encoded as a static in-code map in `code/mcp/mcp-proxy/catalog.bal` — enumerates all seven mesh services with owner, slack channel, repo URL, runbook IDs, health endpoint, and declared dependencies. The dependency edges match the Phase 2 topology exactly so `get_dependencies` returns the real graph (including the `order → notification` async edge). Production would load from a real CMDB.

**MCP Gateway (optional):** the MCP Proxy may be registered behind WSO2 API Manager's MCP Gateway. If used, auth is deferred to the gateway — but verify the gateway does **not** buffer SSE, or streaming `run_runbook` output breaks.

## Agent (client)

The incident-response **Ballerina agent** (`code/agent/`) runs under WSO2 Agent Manager on Kubernetes/kind. See [`todo/phase-4-agent.md`](todo/phase-4-agent.md).

- **Framework / LLM:** Ballerina, native tool-use loop — no SDK required. LLM backend is configurable via `LLM_PROVIDER`: `ollama` (local, creds-free, default), `anthropic` (Anthropic Messages API), `openai` (OpenAI or any compatible endpoint), `amp` (WSO2 AMP AI gateway, OpenAI-compatible; AMP injects the endpoint URL). All logic is in `code/agent/llm_client.bal`; `anthropic_client.bal` handles the Anthropic-specific response format. Packaged as a Docker image built from `code/agent/Dockerfile`. OTel instrumentation is native — `ballerinax/jaeger` + `ballerinax/prometheus` (default, same pattern as the mesh services), plus an optional `ballerinax/amp` exporter that ships this agent's own trace straight to the AMP Console instead (see [Agent tracing → the AMP Console](#agent-tracing--the-amp-console-optional)).
- **MCP wiring:** connects to the MCP Proxy (`:8290`) via `BALLERINA_TOPOLOGY_MCP_URL` using `code/agent/mcp_client.bal`. The proxy handles routing to the Splunk and Datadog MCP backends — swapping to live vendor MCPs requires only changing `SPLUNK_MCP_URL` / `DATADOG_MCP_URL` on the proxy, with no agent changes.
- **Behavior / guardrail:** the system prompt drives a 10-step triage loop — monitors → metrics → trace → correlate → logs → blast radius → deploys → history → **propose a runbook before running it** → summarize. Topology tools are always in context; Splunk/Datadog tools are loaded on demand via `discover_tools` (lazy loading — scales to the real vendor MCPs which expose 50+ tools each). The **propose-before-act** guardrail is hard: the agent must call `list_runbooks` and present its choice for human approval *before* it may call `run_runbook`. Max turns (`30`) and model are configurable via env vars.
- **Triggers:** `POST /investigate` (structured alert body) or `POST /webhook/alert` (Datadog webhook format) — both exposed on `:8080`. In the live demo, a **Datadog-monitor webhook** fires `POST /webhook/alert` automatically when the `payment-service` error rate exceeds threshold.
- **Self-observability (the meta-win):** by default, the agent's OTel spans flow through the same OTel Collector as the mesh — its reasoning trace, per-LLM-call latency, and tool-call durations are visible in Datadog alongside the workload it's diagnosing. The agent watches the workload; Datadog watches the agent. Set `AMP_TRACING_PROVIDER=amp` in `compose/.env` to instead (or additionally) send the agent's own trace straight to the **WSO2 AMP Console's Traces view** — see below.

### WSO2 Agent Manager — quick-start

Agent Manager runs via a self-contained Docker quick-start container. It creates its own internal k3d cluster. This is **separate** from the `devops-poc` compose stack — the agent pod reaches compose services via `host.k3d.internal` (k3d registers this hostname in every pod to resolve back to the Docker host).

```bash
# Install (15–20 min — downloads k3d + Agent Manager control plane)
# Rancher Desktop supports --network=host; Colima setup from the official docs is not needed.
docker run --rm --name amp-quick-start \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --network=host \
  ghcr.io/wso2/amp-quick-start:v0.16.0 \
  ./install.sh

# Console: http://localhost:3000  (amp-admin / amp-admin)
# Observability gateway: http://localhost:22893/otel
# Uninstall (keep cluster): ./uninstall.sh inside the container
# Uninstall + delete cluster: ./uninstall.sh --delete-cluster
```

### Agent tracing → the AMP Console (optional)

The agent does **not** need to be Platform-Hosted to show up in AMP's own
Traces view — it just needs to ship its OTel trace to AMP's observability
gateway instead of (or alongside) the local OTel Collector. This works for the
Compose-run agent (the default demo path) too:

1. In the AMP Console (`http://localhost:3000`), register the agent under
   **Setup Agent** as an externally-hosted agent and generate an API key —
   copy it immediately, it is shown once.
2. In `compose/.env`, set:
   ```
   AMP_TRACING_PROVIDER=amp
   AMP_API_KEY=<the key from step 1>
   ```
   (`AMP_OTEL_ENDPOINT` already defaults to `http://host.docker.internal:22893/otel`,
   which reaches the quick-start container from inside Compose — `localhost`
   only works for a bare, non-containerized `bal run`.)
3. `docker compose -f compose/docker-compose.yml up -d --force-recreate devops-oversight-agent`
4. Trigger an investigation, then open **Observability → Traces** in the AMP
   Console: the root span shows end-to-end latency, LLM spans show token
   counts, tool spans show inputs/outputs.

This is implemented via the official [`ballerinax/amp`](https://central.ballerina.io/ballerinax/amp)
observability extension per WSO2's
[Observe Your First Agent](https://wso2.github.io/agent-manager/docs/v0.18.x/tutorials/observe-first-agent/)
tutorial — see `code/agent/tracing.bal` and `code/agent/Config.toml`
(`[ballerinax.amp]`). Leave `AMP_TRACING_PROVIDER` unset to keep the default
`jaeger` → OTel Collector → Datadog/Splunk path; nothing else changes.

Once the control plane is up, create a **Platform-Hosted** agent in `http://localhost:3000`:

**Agent config:**

| Field | Value |
|-------|-------|
| Git Project | `https://github.com/BechtelCanDoIt/DevOpsOverSightAgent/tree/main` |
| Display Name | `DevOps OverSight Agent` |
| Description | AI agent that correlates Splunk logs and Datadog metrics to diagnose and remediate incidents in the retail mesh |
| Build Context | `code/agent` |
| Dockerfile Path | `code/agent/Dockerfile` |
| Exposed Port | `8080` |
| Health Check Path | `/health` |

**Environment variables / secrets — agent container (mock mode):**

| Variable | Value | Note |
|----------|-------|------|
| `LLM_PROVIDER` | `anthropic` or `amp` | `anthropic` = direct API; `amp` = AMP AI gateway routes to any model |
| `ANTHROPIC_API_KEY` | `sk-ant-…` | Required when `LLM_PROVIDER=anthropic` |
| `BALLERINA_TOPOLOGY_MCP_URL` | `http://host.k3d.internal:8290` | The agent connects **only** to the MCP Proxy; `host.k3d.internal` resolves to the Docker host from inside the k3d pod |
| `OTEL_SERVICE_NAME` | `devops-oversight-agent` | — |

> **`SPLUNK_MCP_URL` and `DATADOG_MCP_URL` belong on the proxy, not the agent.** The agent talks to one endpoint (`BALLERINA_TOPOLOGY_MCP_URL`). Set `SPLUNK_MCP_URL=http://host.k3d.internal:8400` and `DATADOG_MCP_URL=http://host.k3d.internal:8401` as env vars on the `mcp-proxy` container (or the AMP component that runs it) if the proxy also runs in k3d. If the proxy runs in compose (the default), those URLs stay as the compose-internal defaults and no override is needed.

> When `LLM_PROVIDER=anthropic`, AMP automatically injects `ANTHROPIC_URL` so all Anthropic calls route through AMP's AI gateway (rate-limiting, audit, token tracking). When `LLM_PROVIDER=amp`, AMP injects `LLM_BASE_URL` for its OpenAI-compatible gateway — set `LLM_MODEL` to the model you want AMP to route to. You do **not** set `ANTHROPIC_URL` or `LLM_BASE_URL` yourself; they are AMP-injected.

**Verify and trigger:**

```bash
# Health check (AMP proxies :8082 → pod :8080 by default)
curl http://localhost:8082/health

# Trigger a structured investigation
curl -X POST http://localhost:8082/investigate \
  -H "Content-Type: application/json" \
  -d '{"service":"payment-service","severity":"P1","description":"502 spike"}'

# AMP chat endpoint (Platform-Hosted agents)
curl -X POST http://localhost:8082/chat \
  -H "Content-Type: application/json" \
  -d '{"message":"Why is payment-service failing?","sessionId":"demo-1"}'
```

---

## See also

- **[`CLAUDE.md`](CLAUDE.md)** — locked decisions, data flows, and known gotchas (trace-ID mismatch, NATS async propagation, SSE buffering, pod→compose reachability).
- **[`architecture.md`](architecture/architecture.md)** — the deep dive: topology diagrams, telemetry fan-out, correlation and remediation flows.
- **[`todo/README.md`](todo/README.md)** — the phased build plan and per-phase exit criteria.
- **[`tests/README.md`](tests/README.md)** — per-service unit test inventory: every test name and what it covers.
