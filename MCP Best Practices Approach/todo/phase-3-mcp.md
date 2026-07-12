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

- [ ] **[trace-ID width reconciliation — required before live-backend wiring]** `correlate_trace` currently substitutes the supplied trace id verbatim into both the Datadog URL and the Splunk SPL with no 64-bit ↔ 128-bit normalization. Datadog surfaces both `dd.trace_id` (64-bit decimal or hex) and `otel.trace_id` (128-bit, 32-char hex); Splunk holds the 128-bit form. If the agent passes the 64-bit id to `correlate_trace`, the Splunk search will return zero results and the agent will wrongly conclude "no logs found." This is the most important correctness detail in the pipeline. Fix: inspect both id fields returned by `datadog__get_datadog_trace`, pass the 128-bit form to `correlate_trace` (or have `correlate_trace` accept both and normalize). Confirm the correct field name during Phase 1 live smoke test and lock the behavior here before declaring Phase 3 done against live backends.

### 3.4 Runbook execution
- [x] Runbooks live in `runbooks.bal` (4 runbooks: `restart-service`, `clear-cache`, `disable-chaos`, `freeze-deploys`)
- [ ] **[SSE streaming not implemented]** Runbooks return a `string[]` steps array in a single JSON response instead of streaming via SSE. This is sufficient for the demo (the agent renders each step as text), but differs from the spec intent. If the MCP Gateway is wired in, verify it does not buffer the response anyway — if it does, the SSE design would have broken silently. Track here; promote to a real SSE response only if the demo narrative requires visible progress streaming.
- [x] Audit log: every `run_runbook` call appends to an isolated in-memory `auditLog` via `appendAudit`; `getAuditLog()` exposed for inspection
- [ ] **[audit log and deploy-freeze state are in-memory only]** Both the runbook audit log and the deploy-freeze flag are process-scoped (lost on restart). For the demo this is acceptable (short-lived stack). For production, these MUST be persisted to a durable store (a DB table, a file, or a dedicated remediation-MCP). Mark as a known non-durable shortcut; add a `persist-audit` task here if durability is required before shipping.

### 3.5 Auth
- [ ] Bearer token check on every request (token in env var, same as Splunk/Datadog) — not yet implemented
- [ ] If using API Manager MCP Gateway, defer auth to it

### 3.6 Verification
- [ ] Run the MCP server, connect with an MCP inspector (e.g. `npx @modelcontextprotocol/inspector`)
- [ ] Call each tool, confirm responses
- [ ] Run a chaos scenario in Phase 2 mesh, call `correlate_trace` with a real trace_id, confirm the returned Datadog + Splunk links work
- [ ] Call `run_runbook("disable-chaos", { service: "payment-service" })`, confirm chaos resets

### 3.7 Unit tests
- [x] Tests written and passing (`code/mcp/mcp-proxy/tests/mcp_server_test.bal` + `tests/federation_test.bal`)
  - Catalog: lookup known/unknown, list count, dependency graph (downstream, upstream, both, leaf)
  - Correlation: Datadog URL format, custom site, SPL content, infer services
  - Deploy stub: find deploys for known/unknown service
  - Runbooks: list count, `disable-chaos` present, execute 4 runbooks, unknown runbook errors, audit log populated
  - **Test count note:** this phase originally tracked "22 tests." A full `function test` grep across the mcp-proxy package now yields ~41 test functions (both test files combined), reflecting additions made during Phases 3–4 development. The "22" figure in `README.md`/`CLAUDE.md` is stale. Verify the actual count with `cd code/mcp/mcp-proxy && bal test` and update the README.

## Refactor R3 — architecture hardening (2026-07)

From a from-scratch design review. Three principles reshape the MCP layer: **MCP is the trust boundary**, **read and write are different trust tiers**, and **correlation is the product** (a real cross-backend join, not a link-builder). Items below are scoped to the MCP layer; the two cross-phase dependencies are called out inline.

````
I'll reason from first principles about what this system is — an AI SRE that reads across two observability backends and closes the loop on incidents — and design toward that, then note where it lines up with (or would diverge from) what you've built.

Design philosophy

Three principles drive the whole shape:

1. MCP is the contract boundary, not just a transport. Everything the agent can see or do is a tool. That means the mesh, Splunk, Datadog, and remediation are all behind the same uniform interface — and swapping a mock for a live vendor is a config change, never a code change. You already landed here; I'd double down on it.
2. Read and write are different trust tiers. Diagnosis tools are free-to-call; remediation tools pass through an approval/policy gate. This is the single most important safety property for an "agent that fixes prod."
3. Correlation is the actual product. The hard, differentiating work is joining a Splunk log line to a Datadog span to a topology edge. Everything else is plumbing. So I'd design the telemetry layer to make correlation trivial (shared trace IDs + aligned time windows) rather than leave the agent to guess.

Architecture

                              ┌─────────────────────────────────────┐
                              │      WSO2 Agent Manager (govern)     │
                              │  policy · agent OTel · audit · quota │
                              └──────────────────┬──────────────────┘
                                                 │ observes/governs
   TRIGGER                                       ▼
 ┌──────────────┐  incident   ┌───────────────────────────────────────┐
 │ DD monitor   │────webhook─▶│            DevOps Agent                 │
 │ /investigate │             │  ┌─────────────────────────────────┐   │
 │ (manual)     │             │  │ LLM tool-use loop (maxTurns~30) │   │
 └──────────────┘             │  │  system prompt + runbooks       │   │
                              │  │  discover → query → correlate → │   │
                              │  │  hypothesize → propose fix      │   │
                              │  └─────────────────────────────────┘   │
                              │  LLM_PROVIDER: anthropic|amp|openai|.. │
                              └───────────────────┬─────────────────────┘
                                                  │ MCP (one client)
                                                  ▼
                              ┌───────────────────────────────────────┐
                              │             MCP Proxy                  │
                              │  auth (bearer) · audit log · runbooks  │
                              │  tool registry · READ vs WRITE tier    │
                              └───┬───────────────┬───────────────┬────┘
                    READ tools    │               │       WRITE tools│  (gated)
                   ┌──────────────▼──┐   ┌─────────▼────────┐  ┌──────▼────────┐
                   │ Splunk MCP      │   │ Datadog MCP      │  │ Remediation   │
                   │ (logs/search)   │   │ (metrics/APM/    │  │ MCP           │
                   │ mock ⇄ live     │   │  traces) mock⇄live│  │ restart/scale/│
                   └────────▲────────┘   └────────▲─────────┘  │ flag/chaos    │
                            │                     │            └──────┬────────┘
                            │ query               │ query            │ actuate
                   ┌────────┴─────────────────────┴──────┐           │
                   │   Splunk Cloud        Datadog        │           │
                   │   (HEC index)         (metrics/APM)  │           │
                   └────────▲─────────────────────▲───────┘           │
                            │ logs                │ metrics/traces    │
                   ┌────────┴─────────────────────┴───────┐           │
                   │        OTel Collector (fan-out)       │           │
                   │  splunk_hec exporter · datadog exporter│          │
                   └───────────────────▲───────────────────┘           │
                                       │ OTLP (traces/metrics/logs)     │
                   ┌───────────────────┴────────────────────┐          │
                   │        Ballerina 7-service mesh         │◀─────────┘
                   │  gateway→ order→ payment→ inventory→...  │  control
                   │  + load-gen   + chaos endpoints         │  plane
                   └─────────────────────────────────────────┘

Layer-by-layer rationale

Mesh + telemetry (bottom). Instrument once with OpenTelemetry, emit OTLP, and let a single collector fan out. This is exactly your locked decision and it's the right one — the mesh stays vendor-agnostic and you can add a third backend later by adding one exporter. The one thing I'd treat as non-negotiable: propagate W3C trace context end-to-end so the same trace_id appears in Splunk logs and Datadog spans. That's what makes cross-system correlation a join instead of a heuristic.

Observability backends. Splunk = logs/events, Datadog = metrics/APM. Keeping them in their lanes (rather than dual-writing everything everywhere) is what makes the demo interesting — the agent has to correlate two partial views, which is the real SRE skill you're showcasing.

MCP layer — where I'd be most deliberate:
- One proxy, multiple upstream MCP servers. The agent holds a single MCP client; the proxy owns auth, audit, and the tool registry. Vendor mocks sit behind it and swap via env. You have this.
- I'd formalize the READ/WRITE tier split inside the proxy. Read tools (search logs, query metrics, get topology) are auto-approved. Write tools (restart, scale, feature-flag, chaos) require a policy check + optionally a human "approve" step. This is the cleanest place to enforce "the agent can diagnose autonomously but not remediate blindly."
- Runbooks as retrievable context, not hardcoded prompt. Keep them proxy-side so you can iterate on remediation logic without redeploying the agent.

The agent. A bounded tool-use loop: discover tools lazily, query, correlate, hypothesize, propose/apply remediation. The provider-configurable LLM client is a genuinely good call for a POC — it lets you demo on Anthropic and fall back to local Ollama when creds/network are constrained. I'd keep the loop's output structured: a diagnosis object (hypothesis, evidence links, confidence, proposed action) rather than free text, so remediation and the demo UI can consume it.

Trigger + governance. Two entry points (Datadog webhook for realism, /investigate for demos). Agent Manager wraps the agent for policy/observability — importantly, observing the agent itself, which closes the "who watches the watcher" loop nicely for a good governance story.

Where I'd diverge / emphasize differently

- Split remediation into its own MCP server rather than folding chaos/fix actions into the mesh or proxy. It makes the trust boundary physical and the audit story crisp: every write action has one chokepoint.
- Make the diagnosis output a typed contract early. POCs that emit prose are hard to demo repeatably; a structured verdict lets you build a deterministic demo narrative on top of non-deterministic LLM reasoning.

A typed contract means the agent's final output isn't prose — it's a schema-validated object. Something like:

jsonc
{
  "incident_id": "...",
  "root_cause_service": "payment-service",
  "hypothesis": "502s driven by upstream mock-bank timeout under chaos",
  "confidence": 0.82,                    // enum or float, but bounded
  "evidence": [
    { "source": "datadog", "type": "span", "trace_id": "...", "url": "..." },
    { "source": "splunk",  "type": "log",  "query": "...",     "url": "..." }
  ],
  "proposed_action": { "runbook_id": "disable-chaos", "params": { "service": "payment-service" }, "tier": "WRITE" },
  "status": "awaiting_approval"
}

Three things this buys you, in order of importance for a POC:

- Deterministic demo narrative over a non-deterministic core. The reasoning still wanders run-to-run, but the shape of the answer never does. Your demo UI, your slides, your "and here's the verdict" beat — all render the same fields every time. You stop praying the model phrases it well on stage.
- A clean seam to the remediation tier. proposed_action is already a valid run_runbook call. That's what makes the R3.1 approval gate real: you gate on a structured proposal, not on parsing "I think we should probably restart it" out of prose. The typed field is the thing a human (or Agent Manager policy) approves.
- Verifiability / eval. With a schema you can assert in a test that root_cause_service == "payment-service" after injecting a known fault. Prose you can only eyeball. This is how you keep the demo from silently rotting.

The discipline is: the LLM reasons in prose internally, but its final turn must emit the object — enforce it with a forced tool call / structured-output schema, not a "please respond in JSON" instruction. Same pattern as your MCP tool-call validation, just applied to the terminal output. That's the "early" part — retrofitting a contract after the loop is built means unpicking prose-handling assumptions everywhere. (This part is for the agent.yes)

- Correlation-by-trace-id as an explicit tool. Rather than hoping the agent stitches timestamps, give it a correlate_by_trace(trace_id) tool that hits both backends. This turns your differentiator into a first-class capability and shortens the agent loop.

What I'd deliberately defer (and you have)

kind/Agent Manager deployment, live vendor creds, and the SaaS profile are all correctly gated behind "later." The mock-MCP-first approach means the whole thing is demonstrable creds-free, which is the right POC sequencing.

---
Net: your existing architecture is already ~85% of what I'd draw from scratch. The three things I'd invest in if starting over are (1) trace-context propagation as a hard requirement so correlation is a join, (2) an explicit READ/WRITE trust tier with remediation as its own gated MCP server, and (3) a typed diagnosis contract so the demo is repeatable over a non-deterministic core.
````

### R3.1 — Split READ vs WRITE trust tiers inside the proxy
Today all 9 tools sit in one flat registry. Diagnosis (read) and remediation (write) must be different trust tiers so the agent can diagnose autonomously but never remediate blindly.
- [ ] Tag every tool in the registry `READ` or `WRITE` (`lookup_*`, `get_*`, `list_*`, `correlate_*`, `find_*` → READ; `run_runbook` → WRITE)
- [ ] READ tools auto-approve; WRITE tools pass through a policy gate (config-driven: `auto` | `require-approval` | `deny`)
- [ ] When gated, `run_runbook` returns a pending-approval envelope instead of executing; approval resumes it
- [ ] Surface the tier in `tools/list` output so the agent (and Agent Manager policy) can reason about it

### R3.2 — Extract remediation into its own gated MCP server
Fold the runbook engine out of `mcp-proxy` into a dedicated **remediation MCP** so the write boundary is *physical*, not just a tag — one chokepoint for every state-changing action and its audit trail.
- [ ] New `code/mcp/remediation-mcp/` package; move `runbooks.bal` + `auditLog` there
- [ ] Proxy routes `list_runbooks` / `run_runbook` to it as an upstream (READ vs WRITE tier from R3.1 still enforced at the proxy edge)
- [ ] Per-runbook lock lives here (also closes the idempotency pitfall below)
- [ ] Audit log is the server's single responsibility — every write action has exactly one recorded chokepoint

### R3.3 — Runbooks as retrievable context, not hardcoded logic
Runbook definitions (name, description, params schema, steps) should be *data the proxy serves*, not compiled-in prompt content — so remediation logic iterates without redeploying the agent.
- [ ] Move runbook definitions to a served catalog (in-code map is fine short-term; the point is the agent retrieves them via `list_runbooks`, never hardcodes them)
- [ ] `list_runbooks` returns rich enough `params_schema` that the agent can construct a valid `run_runbook` call unaided

### R3.4 — Make `correlate_trace` a real cross-backend join
Today it only *builds links* to Splunk/Datadog. Promote it to a first-class capability that actually queries both backends by `trace_id` and returns a unified view — this is the demo's differentiator, so it should be a tool call, not left to the agent to stitch by timestamp.
- [ ] `correlate_trace(trace_id)` fans out to the Splunk + Datadog MCPs and returns `{ involved_services, log_events, spans, links }` joined on `trace_id`
- [ ] Keep the pre-built links as a fallback field for the human-facing demo
- [ ] **Depends on** trace-context propagation (W3C `traceparent`) being enforced end-to-end in the mesh — same `trace_id` must land in *both* Splunk logs and Datadog spans. Add this as a hard requirement in Phase 2; resolves the trace-ID-format pitfall below at the source.

### Cross-phase notes (not owned by Phase 3)
- **Phase 2:** W3C trace-context propagation becomes a hard requirement (prerequisite for R3.4).
- **Phase 4:** agent emits a *typed diagnosis contract* (hypothesis, evidence links, confidence, proposed action) rather than prose, so remediation and the demo UI consume structured output over a non-deterministic core.

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
