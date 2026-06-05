# Phase 3 — Ballerina MCP server

**Goal:** build the MCP server that gives the agent access to **service topology, cross-system correlation, and scoped runbook execution** — the glue between the Splunk MCP and Datadog MCP. Implemented in Ballerina to showcase Ballerina's integration story.

## Why this is a separate MCP

Splunk's MCP knows logs. Datadog's MCP knows metrics and traces. Neither knows your service catalog, owners, dependency graph, or runbooks. This MCP fills that gap — and because it's Ballerina, it can also *act* (call internal APIs, hit chaos endpoints to remediate, etc.) without leaving the demo's tech narrative.

## Transport

Per Phase 0 research, **expose the MCP over Streamable HTTP** (or HTTP/SSE if Streamable HTTP isn't yet on the Agent Manager / API Manager MCP Gateway support matrix). In Kubernetes-land, stdio doesn't work — the MCP needs a network endpoint that the agent pod can reach.

- [ ] Run on `:8290` in the compose stack
- [ ] Register the same endpoint with WSO2 API Manager's **MCP Gateway** if Phase 0 confirmed that's the integration path — gives us auth, rate-limiting, and audit "for free"

## Tools the MCP exposes

### Lookup & topology

| Tool | Inputs | Returns |
|---|---|---|
| `lookup_service` | `name` | `{ owner, repo, runbook_ids, sla, health_endpoint, dependencies }` |
| `get_dependencies` | `name`, `direction` (`upstream`/`downstream`/`both`) | Adjacency list |
| `list_services` | (none) | All known services with last_seen timestamp |
| `get_service_health` | `name` | Probes `/health` live and returns status + latency |

### Correlation

| Tool | Inputs | Returns |
|---|---|---|
| `correlate_trace` | `trace_id` | Datadog APM URL + Splunk search URL pre-filtered to that trace_id, plus involved services |
| `find_recent_deploys` | `service`, `lookback` | Recent deploys (from a stub deploy log) — lets the agent ask "did something change?" |
| `find_related_incidents` | `service`, `lookback` | Stub: queries a local SQLite of "past incidents" to demo learning-from-history |

### Scoped actions (runbooks)

| Tool | Inputs | Returns |
|---|---|---|
| `list_runbooks` | (none) | Array of `{ id, name, description, params_schema }` |
| `run_runbook` | `id`, `params` | Streaming output of runbook execution |

Initial runbooks to ship:
- `restart-service` — calls Docker/K8s API to restart a container/pod
- `clear-cache` — hits Redis FLUSHDB on `inventory-service`'s cache
- `disable-chaos` — calls `/chaos/reset` on a target service (the most-used in the demo)
- `freeze-deploys` — sets a flag in a stub deploy registry

## Tasks

### 3.1 Scaffold
- [ ] `generate/mcp-server/` package (lives with the rest of the Ballerina source under `generate/`). Note: `agent/mcp/` is the *client-side* wiring the Phase 4 agent uses to reach this server — not the server itself
- [ ] Use an MCP SDK if a Ballerina one exists; otherwise implement Streamable HTTP MCP protocol directly (it's a small protocol — request/response over POST + SSE)
- [ ] Same OTel instrumentation as the mesh services — the MCP's own calls show up in Datadog
- [ ] Run in the Docker Compose stack on `:8290` and **publish that port to the host** so the agent in kind can reach it via `host.docker.internal:8290` (or a NodePort / `extraHosts` entry). It is the only host-local MCP — the Splunk and Datadog MCPs are vendor-hosted and reached over the internet

### 3.2 Service catalog source of truth
Two options:
- **Static YAML** committed to repo (`catalog/services.yaml`) — simpler, fine for demo
- **Live discovery** by reading Docker labels — fancier but adds a Docker socket dependency

Recommendation: **static YAML** for the POC, with a comment that production would discover from a real CMDB. Catalog fields per service: name, owner, slack channel, repo URL, runbook IDs, health endpoint, declared dependencies.

The catalog must enumerate **all seven mesh services** (`store`, `customer`, `order`, `inventory`, `invoice`, `payment`, `notification`) with `dependencies` matching the topology in `phase-2-ballerina.md` — so `get_dependencies("payment-service", "downstream")` and friends return the real graph (e.g. `order` → customer/inventory/payment/invoice and the `order` → `notification` async edge).

### 3.3 Correlation logic
The interesting tool. `correlate_trace(trace_id)` is a **pure link + topology helper — it does NOT call vendor REST APIs.** The agent pulls the actual logs/traces through the official Splunk and Datadog MCPs (`splunk_run_query`, `get_datadog_trace`); this tool just tells it where to look. It should:
1. Compute the Datadog APM deep-link URL `https://app.{dd_site}/apm/trace/{trace_id}` — read `dd_site` (e.g. `datadoghq.com`, `us5.datadoghq.com`) from a **config file, never hardcode it**
2. Compute the Splunk search URL / SPL (`index=* trace_id={trace_id}`) pre-filled
3. Return the topology-derived list of services likely involved (from the static catalog) so the agent knows where to search
4. Return all of the above so the agent can *link to* Datadog/Splunk and then *fetch* the data via their MCPs

> Important: build this around the actual trace ID format you see in Datadog (64-bit vs 128-bit) — confirm during Phase 1's smoke test.

### 3.4 Runbook execution
- [ ] Runbooks live in `mcp-server/runbooks/*.bal` as Ballerina functions
- [ ] Each runbook returns a streaming progress feed (use SSE so the agent can show intermediate steps)
- [ ] Audit log: every `run_runbook` call appends to `audit.log` with who/what/when/result

### 3.5 Auth
- [ ] Bearer token check on every request (token in env var, same as Splunk/Datadog)
- [ ] If using API Manager MCP Gateway, defer auth to it

### 3.6 Verification
- [ ] Run the MCP server, connect with an MCP inspector (e.g. `npx @modelcontextprotocol/inspector`)
- [ ] Call each tool, confirm responses
- [ ] Run a chaos scenario in Phase 2 mesh, call `correlate_trace` with a real trace_id, confirm the returned Datadog + Splunk links work
- [ ] Call `run_runbook("disable-chaos", { service: "payment-service" })`, confirm chaos resets

## Pitfalls

- **Trace ID format mismatch** with Datadog — already flagged in Phase 1, but it'll bite here when the agent says "no logs found for this trace" because Splunk has the 128-bit form and Datadog showed the 64-bit form.
- **Runbook idempotency** — if the agent calls `restart-service` twice while the first is still running, what happens? Add a per-runbook lock.
- **SSE through API Manager MCP Gateway** — if the gateway buffers responses, streaming runbook output won't work. Test early.

## Deliverables

- Running Ballerina MCP server with at least 8 tools (4 lookup, 3 correlation, plus `list_runbooks` + `run_runbook`)
- 4 working runbooks
- An MCP Inspector session screenshot showing the tool list
- An end-to-end test: inject chaos → query MCP for correlation → run the reset runbook → verify mesh recovers

## Exit criteria

An operator (human) can complete a full incident triage using only MCP tool calls: find the failing service, see the correlated logs, and remediate via runbook. If a human can do it, the agent can.
