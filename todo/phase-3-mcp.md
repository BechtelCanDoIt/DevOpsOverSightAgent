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
- [x] `code/mcp/mcp-proxy/` package (lives under `code/mcp/`). Note: the Phase 4 agent's `mcp_client.bal` is the client-side wiring — not part of this server
- [x] No Ballerina MCP SDK exists — implemented Streamable HTTP MCP protocol directly (JSON-RPC 2.0 over POST to `/mcp`; `initialize` handshake, `tools/list`, `tools/call`)
- [x] Same OTel instrumentation as the mesh services — `tracing.bal` wires jaeger + prometheus side-effect imports; the MCP's own calls show up in Datadog
- [x] Runs in the Docker Compose stack on `:8290` with host port published; agent connects via `http://mcp-proxy:8290` inside the compose network

### 3.2 Service catalog source of truth
**Implemented as a static in-code map** (`catalog.bal`) rather than YAML — all seven mesh services with exact dependency edges matching `phase-2-ballerina.md`, including the async `order → notification` NATS edge modelled in a separate `ASYNC_EDGES` map. Production comment included pointing to CMDB.

The catalog enumerates all seven services (`store`, `customer`, `order`, `inventory`, `invoice`, `payment`, `notification`) with owner, slack channel, repo URL, runbook IDs, SLA, health endpoint, and declared dependencies — `get_dependencies("order-service", "downstream")` returns `[customer, inventory, payment, invoice, notification]` correctly.

### 3.3 Correlation logic
**Implemented** (`correlation.bal`) as a pure link + topology helper — does NOT call vendor REST APIs. Agent pulls actual data via Splunk and Datadog MCPs; this tool tells it where to look:
1. `buildDatadogTraceUrl(traceId, ddSite)` → `https://app.{dd_site}/apm/trace/{trace_id}` — `DD_SITE` read from env
2. `buildSplunkSpl(traceId)` → pre-filled SPL `index=* trace_id="..." | table _time, service, trace_id, ...`
3. `buildSplunkSearchUrl(traceId, splunkUrl)` → URL-encoded search link
4. `inferInvolvedServices(traceId)` → returns all 7 mesh services (full catalog — no trace sampling yet)

Stub deploy log and incident history also live in `correlation.bal` — `find_recent_deploys` and `find_related_incidents` work against in-memory data.

> Note: trace ID format (64-bit vs 128-bit Datadog) still needs confirmation during Phase 1 live smoke test.

### 3.4 Runbook execution
- [x] Runbooks live in `runbooks.bal` (4 runbooks: `restart-service`, `clear-cache`, `disable-chaos`, `freeze-deploys`)
- [ ] SSE streaming not implemented — runbooks return a `string[]` steps array instead (sufficient for demo; the agent renders each step as text)
- [x] Audit log: every `run_runbook` call appends to an isolated in-memory `auditLog` via `appendAudit`; `getAuditLog()` exposed for inspection

### 3.5 Auth
- [ ] Bearer token check on every request (token in env var, same as Splunk/Datadog) — not yet implemented
- [ ] If using API Manager MCP Gateway, defer auth to it

### 3.6 Verification
- [ ] Run the MCP server, connect with an MCP inspector (e.g. `npx @modelcontextprotocol/inspector`)
- [ ] Call each tool, confirm responses
- [ ] Run a chaos scenario in Phase 2 mesh, call `correlate_trace` with a real trace_id, confirm the returned Datadog + Splunk links work
- [ ] Call `run_runbook("disable-chaos", { service: "payment-service" })`, confirm chaos resets

### 3.7 Unit tests
- [x] 22 `@test:Config` tests written and passing (`code/mcp/mcp-proxy/tests/mcp_server_test.bal`)
  - Catalog: lookup known/unknown, list count, dependency graph (downstream, upstream, both, leaf)
  - Correlation: Datadog URL format, custom site, SPL content, infer services
  - Deploy stub: find deploys for known/unknown service
  - Runbooks: list count, `disable-chaos` present, execute 4 runbooks, unknown runbook errors, audit log populated

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
