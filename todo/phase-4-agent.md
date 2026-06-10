# Phase 4 — Ballerina Agent

**Goal:** build a Ballerina agent that calls the Anthropic Messages API in a tool-use loop, wires to three MCP servers (Splunk, Datadog, Ballerina topology), and deploys into the Docker Compose stack. The agent also ships two **mock MCP servers** so the end-to-end investigation loop can be exercised locally before live Splunk/Datadog credentials arrive.

## Why Ballerina (not Python) for the agent

Phase 0 originally planned Python for WSO2 Agent Manager auto-instrumentation. That decision was reversed: the entire stack is Ballerina, Ballerina's OTel support is sufficient for Agent Manager's needs, and keeping one language eliminates a Python dependency, a separate `agent/` directory, and the `claude-agent-sdk` pip package. The Claude API is called directly via Ballerina's HTTP client — no SDK adapter needed.

## Source layout

| Package | Port | Purpose |
|---|---|---|
| `generate/agent/` | 8080 | DevOps agent — Anthropic tool-use loop + HTTP trigger endpoints |
| `generate/splunk-mock-mcp/` | 8400 | Mock Splunk MCP — mirrors Splunkbase app 7931 interface; used until real creds arrive |
| `generate/datadog-mock-mcp/` | 8401 | Mock Datadog MCP — mirrors `mcp.datadoghq.com` interface; used until real creds arrive |

The real Splunk and Datadog MCP URLs are injected at runtime via env vars; the mock servers are the default values. Swapping to live vendor MCPs requires only `.env` changes — no code changes.

## Tasks

### 4.1 Agent scaffold
- [x] `generate/agent/` Ballerina package (`devopspoc/devops_agent`)
- [x] `anthropic_client.bal` — Anthropic Messages API client; implements `runAgentLoop(apiKey, model, systemPrompt, userPrompt, tools, dispatcher, maxTurns)` with full tool-use loop (handles `tool_use` stop_reason, accumulates `tool_result` blocks, loops until `end_turn` or max turns)
- [x] `mcp_client.bal` — minimal MCP HTTP client; `mcpInitialize`, `mcpListTools`, `mcpCallTool` over JSON-RPC 2.0 POST to `/mcp`
- [x] `prompts.bal` — `SYSTEM_PROMPT` (investigation protocol, all three MCPs, propose-before-act guardrail) and `buildInvestigationPrompt`
- [x] `devops_agent.bal` — HTTP listener on `:8080`; `POST /investigate` (structured alert body) + `POST /webhook/alert` (Datadog webhook format); both call `investigate()` and return a JSON summary
- [x] `obs.bal` / `tracing.bal` — OTel instrumentation (same pattern as mesh services)
- [x] `Config.toml` + `Ballerina.toml` — `observabilityIncluded = true`, configurable MCP URLs defaulting to compose service names

### 4.2 Mock MCP servers

Two mock servers allow local development and end-to-end testing without live Splunk/Datadog accounts.

#### Splunk mock MCP (`generate/splunk-mock-mcp/`, port 8400)
- [x] Implements the Splunkbase app 7931 tool interface: `splunk_run_query`, `splunk_get_indexes`, `splunk_get_knowledge_objects`, `splunk_list_saved_searches`, `splunk_preview_search`
- [x] `mock_data.bal` returns realistic log data for the demo scenario — `payment-service` 502 errors with `trace_id` fields, latency spikes, normal baseline traffic
- [x] 8 `@test:Config` tests passing (`generate/splunk-mock-mcp/tests/`)

#### Datadog mock MCP (`generate/datadog-mock-mcp/`, port 8401)
- [x] Implements the `mcp.datadoghq.com` tool interface: `get_datadog_metric`, `search_datadog_metrics`, `search_datadog_error_tracking_issues`, `get_datadog_trace`, `apm_search_spans`, `search_datadog_logs`, `search_datadog_monitors`
- [x] `mock_data.bal` returns a pre-built APM trace showing `order-service → payment-service` latency, a fired Datadog monitor for `payment-service` 502 rate, and matching log events
- [x] 11 `@test:Config` tests passing (`generate/datadog-mock-mcp/tests/`)

### 4.3 MCP wiring — tool namespacing
The agent connects to all three MCPs at startup, lists tools from each, and prefixes tool names with the server namespace (`splunk__`, `datadog__`, `topology__`). The dispatcher routes on the prefix:

```
splunk__splunk_run_query      → splunk-mock-mcp:8400  (or live Splunk MCP)
datadog__get_datadog_trace    → datadog-mock-mcp:8401 (or mcp.datadoghq.com)
topology__correlate_trace     → mcp-server:8290
```

MCP server URLs come from env vars with compose-internal defaults:
- `SPLUNK_MCP_URL` (default `http://splunk-mock-mcp:8400`)
- `DATADOG_MCP_URL` (default `http://datadog-mock-mcp:8401`)
- `BALLERINA_TOPOLOGY_MCP_URL` (default `http://mcp-server:8290`)

### 4.4 System prompt + agent behavior
- [x] System prompt defines investigation protocol (10 steps: monitors → metrics → trace → correlate → logs → blast radius → deploys → history → propose runbook → summarize)
- [x] Propose-before-act guardrail: agent must call `topology__list_runbooks`, explain its choice, then WAIT before calling `topology__run_runbook`
- [x] `AGENT_MODEL` env var selects the Claude model (default `claude-sonnet-4-6`)
- [x] `max_tokens: 8192`, `maxTurns: 20` — configurable via env/Config.toml

### 4.5 Trigger mechanism
- [x] `POST /investigate` — structured `AlertRequest` body `{ service, severity, description, id }` — primary trigger for demo
- [x] `POST /webhook/alert` — Datadog webhook-format body (`service`, `severity`, `title`/`description`, `id`) — realistic trigger for the live demo scenario
- [ ] Datadog monitor configured in the SaaS console to fire the webhook when `payment-service` error rate exceeds threshold — blocked on `DD_API_KEY`

### 4.6 Docker Compose wiring
- [x] `devops-agent` service in `compose/docker-compose.yml` — builds from `../generate/agent`, port `8080:8080`, health-checked on `/health`
- [x] `splunk-mock-mcp` service — port `8400:8400`
- [x] `datadog-mock-mcp` service — port `8401:8401`
- [x] All three MCP URL env vars wired; switching to live vendors is a `.env` change only

### 4.7 Unit tests
- [x] 8 `@test:Config` tests in `generate/agent/tests/agent_test.bal` — all passing
  - `buildInvestigationPrompt` includes service/severity/description/alertId
  - `SYSTEM_PROMPT` mentions all three MCPs and includes propose-before-act guardrail
  - `splitOnFirst` happy path, double separator, not-found error
  - `envOrCfg` fallback

### 4.8 WSO2 Agent Manager deployment (optional — not blocking for demo)
Agent Manager's Python auto-instrumentation init container (`amp-python-instrumentation-provider`) does not apply to Ballerina. Ballerina's `observabilityIncluded = true` flag provides equivalent OTel traces natively. Agent Manager can still host the Ballerina agent container if desired.

- [ ] Create a Project in `amp-console`
- [ ] Create an Internal Agent definition pointing at `devops-poc/devops-agent:latest`
- [ ] Configure secrets: `ANTHROPIC_API_KEY`, MCP URLs, `DD_SITE`, `SPLUNK_HEC_TOKEN`
- [ ] Deploy and verify pod starts; confirm `/health` returns 200
- [ ] Trigger an investigation; confirm traces appear in `amp-trace-observer`

## Pitfalls

- **MCP init failures are non-fatal**: if a mock MCP is down at startup, the agent logs a warning and continues with the tools from the remaining servers. The investigation will degrade gracefully rather than crashing.
- **Tool name collisions**: if Splunk and Datadog both expose a tool called `search_logs`, the prefix namespace (`splunk__` vs `datadog__`) prevents collision. Anthropic tool names must be unique across the full list.
- **Max tokens vs max turns**: the agent loop exits on `end_turn` or after 20 turns. A very detailed investigation (many tool calls) may require increasing `max_tokens` or `maxTurns`.
- **Swapping to live vendor MCPs**: Datadog MCP (`mcp.datadoghq.com`) uses OAuth or API+APP key headers — the mock uses a bearer token. The `mcp_client.bal` auth header will need to be parameterized when switching.

## Deliverables

- [x] `generate/agent/` — Ballerina agent package, builds clean, 8 unit tests passing
- [x] `generate/splunk-mock-mcp/` — 5 tools, 8 tests passing
- [x] `generate/datadog-mock-mcp/` — 7 tools, 11 tests passing
- [x] All three services wired into `compose/docker-compose.yml`
- [ ] End-to-end investigation test: `POST /investigate` against the live mesh → agent calls all three MCPs, proposes `disable-chaos`, returns a coherent summary
- [ ] A recorded agent trace in `amp-trace-observer` (if Agent Manager deployment done)

## Exit criteria

`POST /investigate { service: "payment-service", severity: "P1", description: "502 spike" }` → the agent calls at least one tool from each of the three MCPs, proposes the `disable-chaos` runbook, and returns a summary containing the trace_id, involved services, and Splunk + Datadog evidence links. Observable end-to-end without live vendor credentials (mocks satisfy the exit criterion).
