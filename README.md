# DevOps Observability POC

A local-first demo: a Ballerina retail microservice mesh emits traces, logs, and metrics through a single OTel Collector to **Splunk** (logs/traces) and **Datadog** (APM/metrics). A ballerina agent running under **WSO2 Agent Manager** correlates those signals over MCP to diagnose and remediate a chaos-induced incident.

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

---

## Usage

### Unit tests — no Docker, no keys needed

```
  make test-bal
  This runs bal test across all 12 packages. You'll see pass/fail per package. Expected: 129 total passing.

  Individual packages:
  cd generate/mcp-server && bal test        # 22 tests
  cd generate/splunk-mock-mcp && bal test   # 8 tests
  cd generate/datadog-mock-mcp && bal test  # 11 tests
  cd generate/agent && bal test             # 8 tests
```

  ---
### Run the full stack (mock mode — no Splunk/Datadog/Anthropic creds needed for health checks)

```
  make demo-mock-up
  Then verify all four new services are up:
  curl http://localhost:8092/health   # devops-oversight-agent (host 8082 collides with Colima's AMP VM forward)
  curl http://localhost:8290/health   # mcp-server
  curl http://localhost:8400/health   # splunk-mock-mcp
  curl http://localhost:8401/health   # datadog-mock-mcp
```

  ---
### Inspect the MCP server tools interactively

The Ballerina MCP server speaks **Streamable HTTP** (plain HTTP POST at `/mcp`) — not STDIO. The inspector must be told that explicitly; passing the URL as a positional arg to the CLI causes `spawn … ENOENT`.

**Step-by-step:**

1. Make sure `mcp-server` is running (`curl http://localhost:8290/health` → `{"status":"UP"}`).

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

5. Click the **Tools** tab → **List Tools**. You'll see all 9 tools (`list_services`, `lookup_service`, `get_dependencies`, `get_service_health`, `correlate_trace`, `find_recent_deploys`, `find_related_incidents`, `list_runbooks`, `run_runbook`).

6. **Call a tool manually** — click any tool, fill in the inputs, click **Run Tool**:
   - `list_services` — no inputs — returns all 7 mesh services
   - `lookup_service` → `name: payment-service` — returns owner, deps, runbooks, SLA
   - `get_dependencies` → `name: order-service`, `direction: downstream` — returns dependency graph
   - `correlate_trace` → `trace_id: abc123` — returns Datadog + Splunk URLs for a trace

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
# The agent calls all three MCPs, runs the tool-use loop, and returns a JSON
# summary with its diagnosis + a proposed runbook (it stops for approval before acting).
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
| [`README.md`](README.md) · [`architecture.md`](architecture.md) · [`CLAUDE.md`](CLAUDE.md) | This file (component reference); deep-dive architecture; Claude Code guidance + locked decisions |
| `todo/` | Authoritative phase specs (`phase-0` … `phase-5`) — start with [`todo/README.md`](todo/README.md) |
| `generate/` | Ballerina source — one package per service + `load-gen` + `mcp-server` + `agent` + two mock MCPs |
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

An **agent tier** (WSO2 Agent Manager on Kubernetes/kind) runs a **Ballerina** incident-response agent that reaches three MCP servers — Splunk, Datadog, and the custom Ballerina MCP — to correlate signals and remediate.

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
- **Wiring:** the agent connects via `SPLUNK_MCP_URL` env var; `splunk-mock-mcp` (`:8400`) is the default until live creds arrive. Splunk Cloud trial receives telemetry via the Collector's `splunk_hec` exporter.

### Datadog MCP (official)

- **Server:** the official *Datadog MCP Server* (Bits AI) — **remote-hosted** by Datadog at `https://mcp.datadoghq.com/api/unstable/mcp-server/mcp` (regional per `DD_SITE`; in Preview, under `/api/unstable/` — pin it). Streamable HTTP; auth via OAuth 2.0 or `DD_API_KEY` + `DD_APPLICATION_KEY` headers. Toolsets selected via `?toolsets=apm,...`.
- **Role / tools (real names):** metrics — `get_datadog_metric`, `search_datadog_metrics`; errors — `search_datadog_error_tracking_issues`; APM traces — `get_datadog_trace` (full trace by ID), `apm_search_spans`; logs — `search_datadog_logs`; monitors — `search_datadog_monitors`. (Our earlier `get_service_metrics` / `get_service_errors` were placeholder guesses — these are the actual tools.)
- **Wiring:** the agent connects via `DATADOG_MCP_URL` env var; `datadog-mock-mcp` (`:8401`) is the default until live creds arrive.

### Ballerina MCP (custom)

The glue between Splunk and Datadog: it owns the **service catalog, dependency graph, cross-system correlation, and scoped runbook execution**. Built in Ballerina (so it can both *know* topology and *act* on it), it runs over **Streamable HTTP on `:8290`** (HTTP/SSE fallback). Source lives in `generate/mcp-server/`; the agent connects via `generate/agent/mcp_client.bal` using `BALLERINA_TOPOLOGY_MCP_URL`. Same OTel instrumentation as the mesh, so its own calls show up in Datadog. See [`todo/phase-3-mcp.md`](todo/phase-3-mcp.md).

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

The incident-response **Ballerina agent** (`generate/agent/`) runs under WSO2 Agent Manager on Kubernetes/kind. See [`todo/phase-4-agent.md`](todo/phase-4-agent.md).

- **Framework / LLM:** Ballerina, native tool-use loop — no SDK required. LLM backend is configurable via `LLM_PROVIDER`: `ollama` (local, creds-free, default), `anthropic` (Anthropic Messages API), `openai` (OpenAI or any compatible endpoint), `amp` (WSO2 AMP AI gateway, OpenAI-compatible; AMP injects the endpoint URL). All logic is in `generate/agent/llm_client.bal`; `anthropic_client.bal` handles the Anthropic-specific response format. Packaged as a Docker image built from `generate/agent/Dockerfile`. OTel instrumentation is native (same `ballerinax/jaeger` + `ballerinax/prometheus` pattern as the mesh services).
- **MCP wiring:** connects to all three MCP servers via `generate/agent/mcp_client.bal` — Splunk mock MCP (`:8400`), Datadog mock MCP (`:8401`), and the custom Ballerina MCP (`:8290`). URLs are injected as env vars so swapping to live vendor MCPs requires only `.env` / amp-console secret changes — no code changes.
- **Behavior / guardrail:** the system prompt drives a 10-step triage loop — monitors → metrics → trace → correlate → logs → blast radius → deploys → history → **propose a runbook before running it** → summarize. Topology tools are always in context; Splunk/Datadog tools are loaded on demand via `discover_tools` (lazy loading — scales to the real vendor MCPs which expose 50+ tools each). The **propose-before-act** guardrail is hard: the agent must call `list_runbooks` and present its choice for human approval *before* it may call `run_runbook`. Max turns (`30`) and model are configurable via env vars.
- **Triggers:** `POST /investigate` (structured alert body) or `POST /webhook/alert` (Datadog webhook format) — both exposed on `:8080`. In the live demo, a **Datadog-monitor webhook** fires `POST /webhook/alert` automatically when the `payment-service` error rate exceeds threshold.
- **Self-observability (the meta-win):** the agent's OTel spans flow through the same OTel Collector as the mesh — its reasoning trace, per-LLM-call latency, and tool-call durations are visible in Datadog alongside the workload it's diagnosing. The agent watches the workload; Datadog watches the agent.

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

Once the control plane is up, create a **Platform-Hosted** agent in `http://localhost:3000`:

**Agent config:**

| Field | Value |
|-------|-------|
| Git Project | `https://github.com/BechtelCanDoIt/DevOpsOverSightAgent/tree/main` |
| Display Name | `DevOps OverSight Agent` |
| Description | AI agent that correlates Splunk logs and Datadog metrics to diagnose and remediate incidents in the retail mesh |
| Build Context | `generate/agent` |
| Dockerfile Path | `generate/agent/Dockerfile` |
| Exposed Port | `8080` |
| Health Check Path | `/health` |

**Environment variables / secrets: (For Local Mocks)**

| Variable | Value (mock mode) |
|----------|------------------|
| `LLM_PROVIDER` | `anthropic` to use Anthropic directly; `amp` to let AMP route to any model via its AI gateway |
| `ANTHROPIC_API_KEY` | your Anthropic API key (`sk-ant-…`) — required when `LLM_PROVIDER=anthropic` |
| `SPLUNK_MCP_URL` | `http://host.k3d.internal:8400` |
| `DATADOG_MCP_URL` | `http://host.k3d.internal:8401` |
| `BALLERINA_TOPOLOGY_MCP_URL` | `http://host.k3d.internal:8290` |
| `OTEL_SERVICE_NAME` | `devops-oversight-agent` |

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
- **[`architecture.md`](architecture.md)** — the deep dive: topology diagrams, telemetry fan-out, correlation and remediation flows.
- **[`todo/README.md`](todo/README.md)** — the phased build plan and per-phase exit criteria.
- **[`TESTS-README.md`](TESTS-README.md)** — per-service unit test inventory: every test name and what it covers.
