# Phase 4 — Ballerina Agent

**Goal:** build a Ballerina agent that calls an LLM in a native tool-use loop, wires to three MCP servers (Splunk, Datadog, Ballerina topology), and deploys into the Docker Compose stack (standalone) or WSO2 Agent Manager (AMP). The agent also ships two **mock MCP servers** so the end-to-end investigation loop can be exercised locally before live Splunk/Datadog credentials arrive. The LLM backend is configurable via `LLM_PROVIDER` env var with four providers: `ollama` (default, creds-free), `anthropic`, `openai`, and `amp` (AMP AI gateway, OpenAI-compatible). Switching between local and AMP is purely env-var-driven — no code changes.

## Why Ballerina (not Python) for the agent

Phase 0 originally planned Python for WSO2 Agent Manager auto-instrumentation. That decision was reversed: the entire stack is Ballerina, Ballerina's OTel support is sufficient for Agent Manager's needs, and keeping one language eliminates a Python dependency, a separate `agent/` directory, and the `claude-agent-sdk` pip package. The Claude API is called directly via Ballerina's HTTP client — no SDK adapter needed.

## Source layout

| Package | Port | Purpose |
|---|---|---|
| `code/agent/` | 8080 | DevOps agent — configurable LLM tool-use loop (ollama/anthropic/openai/amp) + HTTP trigger endpoints |
| `code/mcp/splunk-mock-mcp/` | 8400 | Mock Splunk MCP — mirrors Splunkbase app 7931 interface; used until real creds arrive |
| `code/mcp/datadog-mock-mcp/` | 8401 | Mock Datadog MCP — mirrors `mcp.datadoghq.com` interface; used until real creds arrive |

The real Splunk and Datadog MCP URLs are injected at runtime via env vars; the mock servers are the default values. Swapping to live vendor MCPs requires only `.env` changes — no code changes.

## Tasks

### 4.1 Agent scaffold
- [x] `code/agent/` Ballerina package (`devopspoc/devops_oversight_agent`)
- [x] `anthropic_client.bal` — Anthropic Messages API client; implements `runAgentLoop(apiKey, model, systemPrompt, userPrompt, tools, dispatcher, maxTurns)` with full tool-use loop (handles `tool_use` stop_reason, accumulates `tool_result` blocks, loops until `end_turn` or max turns)
- [x] `llm_client.bal` — provider router + all non-Anthropic loops; `runConfiguredLlm` dispatches on `LLM_PROVIDER`; contains `runOllamaLoop` (Ollama `/api/chat`, args as JSON objects) and `runOpenAICompatLoop` (OpenAI + AMP `/v1/chat/completions`, args as JSON strings parsed via `value:fromJsonString`); four providers: `anthropic` (default), `ollama`, `openai`, `amp`
- [x] `mcp_client.bal` — minimal MCP HTTP client; `mcpInitialize`, `mcpListTools`, `mcpCallTool` over JSON-RPC 2.0 POST to `/mcp`
- [x] `prompts.bal` — `SYSTEM_PROMPT` (investigation protocol, all three MCPs, propose-before-act guardrail) and `buildInvestigationPrompt`
- [x] `devops_oversight_agent.bal` — HTTP listener on `:8080` (mapped to `:8092` on host to avoid Colima AMP-VM port collisions); `POST /investigate` (structured alert body) + `POST /webhook/alert` (Datadog webhook format); both call `investigate()` and return a JSON summary
- [x] `obs.bal` / `tracing.bal` — OTel instrumentation (same pattern as mesh services)
- [x] `Config.toml` + `Ballerina.toml` — `observabilityIncluded = true`, configurable MCP URLs + LLM provider opts defaulting to compose service names and Ollama

### 4.2 Mock MCP servers

Two mock servers allow local development and end-to-end testing without live Splunk/Datadog accounts.

#### Splunk mock MCP (`code/mcp/splunk-mock-mcp/`, port 8400)
- [x] Implements the Splunkbase app 7931 tool interface: `splunk_run_query`, `splunk_get_indexes`, `splunk_get_knowledge_objects`, `splunk_list_saved_searches`, `splunk_preview_search`
- [x] `mock_data.bal` returns realistic log data for the demo scenario — `payment-service` 502 errors with `trace_id` fields, latency spikes, normal baseline traffic
- [x] 8 `@test:Config` tests passing (`code/mcp/splunk-mock-mcp/tests/`)

#### Datadog mock MCP (`code/mcp/datadog-mock-mcp/`, port 8401)
- [x] Implements the `mcp.datadoghq.com` tool interface: `get_datadog_metric`, `search_datadog_metrics`, `search_datadog_error_tracking_issues`, `get_datadog_trace`, `apm_search_spans`, `search_datadog_logs`, `search_datadog_monitors`
- [x] `mock_data.bal` returns a pre-built APM trace showing `order-service → payment-service` latency, a fired Datadog monitor for `payment-service` 502 rate, and matching log events
- [x] 11 `@test:Config` tests passing (`code/mcp/datadog-mock-mcp/tests/`)

### 4.3 MCP wiring — tool namespacing
The agent connects to all three MCPs at startup, lists tools from each, and prefixes tool names with the server namespace (`splunk__`, `datadog__`, `topology__`). The dispatcher routes on the prefix:

```
splunk__splunk_run_query      → splunk-mock-mcp:8400  (or live Splunk MCP)
datadog__get_datadog_trace    → datadog-mock-mcp:8401 (or mcp.datadoghq.com)
topology__correlate_trace     → mcp-proxy:8290
```

MCP server URLs come from env vars with compose-internal defaults:
- `SPLUNK_MCP_URL` (default `http://splunk-mock-mcp:8400`)
- `DATADOG_MCP_URL` (default `http://datadog-mock-mcp:8401`)
- `BALLERINA_TOPOLOGY_MCP_URL` (default `http://mcp-proxy:8290`)

### 4.4 System prompt + agent behavior
- [x] System prompt defines investigation protocol (10 steps: monitors → metrics → trace → correlate → logs → blast radius → deploys → history → propose runbook → summarize) — works with any LLM backend
- [x] Propose-before-act guardrail: agent must call `topology__list_runbooks`, explain its choice, then WAIT before calling `topology__run_runbook`
- [x] `AGENT_MODEL` env var selects the Claude model for Anthropic backend (default `claude-sonnet-4-6`)
- [x] `OLLAMA_MODEL` env var selects the Ollama model for Ollama backend (default `qwen3.5:9b`)
- [x] `max_tokens: 8192`, `maxTurns: 30` (bumped from 20; do NOT reduce below 25 — Ollama non-determinism plus `discover_tools` overhead can consume up to 25 turns) — configurable via env/Config.toml

- [x] **Hard code-level approval gate (2026-07, closes the gap below)** — `code/agent/approval.bal` + `makeDispatcher` (`devops_oversight_agent.bal`). Mirrors the LangChain sibling's `HumanInTheLoopMiddleware` + `InMemorySaver` interrupt (Ballerina has no graph/checkpointer runtime, so this is the hand-built equivalent): `topology__run_runbook` is **never** forwarded to the proxy from the LLM-facing dispatcher — every attempt is intercepted, stored as a `PendingRunbook` keyed by a monotonic token, and answered with a `RUNBOOK_HALT_MARKER`-prefixed sentinel. All three tool-use loops (`anthropic_client.bal`, `llm_client.bal`'s Ollama + OpenAI-compat loops) check for that marker immediately after every dispatcher call and hard-stop the turn loop the instant it appears — no further LLM turns are spent, so a non-compliant model cannot retry its way past the gate or narrate a fake success. The **only** code path that can call the proxy's real `run_runbook` is `handleApprovalCommand`, reached exclusively via a separate `"approve <token>"` / `"deny <token>"` chat message parsed in `chat()` *before* the message ever reaches the LLM.
  - **[found + reproduced live]** Before this fix, a real `POST /chat` request to a running qwen2.5:14b-instruct-backed agent — asked an unrelated question ("what is the status of the MI server?") — wandered into the payment-service investigation protocol and autonomously executed `disable-chaos` (×2) and `restart-service` (path=stub) with zero human approval, confirmed via the proxy's audit log. This is the exact scenario the old gap note warned about, caught on camera.
  - **[verified fixed, live, same environment]** Re-running the identical prompt no longer executes anything even when the model reaches for `run_runbook` — confirmed via `topology__get_audit_log` staying at its prior entry count through multiple provocation attempts. Full cycle proven end-to-end: propose → blocked (audit log unchanged) → `deny <token>` → confirmed cancelled, token no longer usable → new proposal → blocked → `approve <token>` → **only now** does a new audit-log entry appear, timestamped to the approval action, not any earlier LLM turn.
  - Unit tests (`code/agent/tests/agent_test.bal`): `testInterceptRunRunbookBlocksAndStoresPending`, `testInterceptRunRunbookNeverExecutesDirectly`, `testTakePendingRunbookIsSingleUse`, `testParseApprovalCommand*` (3), `testHandleApprovalCommand*` (3), `testMakeDispatcherInterceptsRunRunbookWithoutCallingProxy` — 10 new tests, 37 agent tests total, all passing.
  - **Scope note**: this gate protects the agent's own LLM-driven execution path (the demonstrated attack surface — a non-compliant local model). It does not add protection at the MCP-protocol level for other direct callers of the proxy (e.g. MCP Inspector) — that is `PROXY_API_KEY`'s job (Refactor R4.3, `phase-3-mcp.md`), a different threat model. This exactly mirrors the LangChain sibling's own scope: its interrupt is also orchestrator-level, not protocol-level (it has no MCP proxy for topology tools at all).
- [ ] **[typed diagnosis output contract not yet implemented]** The agent's final output is a free-text `summary` string inside `{ status, alert_id, summary }`. Wording varies run-to-run, cannot be auto-validated, and makes the demo narrative non-deterministic. The R3 design review (Phase 3) called for a structured `DiagnosisResult` object: `{ incident_id, root_cause_service, hypothesis, confidence, evidence:[{source, type, trace_id?, url?, query?}], proposed_action:{runbook_id, params, tier}, status }`. Implement by: (a) defining the type, (b) enforcing it via a final structured tool call or structured-output schema in the LLM loop, (c) returning it alongside the narrative summary. Do this before adding more test scenarios — retrofitting a typed contract after prose-handling assumptions are baked in is significantly harder.

### 4.5 Trigger mechanism
- [x] `POST /investigate` — structured `AlertRequest` body `{ service, severity, description, id }` — primary trigger for demo
- [x] `POST /webhook/alert` — Datadog webhook-format body (`service`, `severity`, `title`/`description`, `id`) — realistic trigger for the live demo scenario
- [ ] Datadog monitor configured in the SaaS console to fire the webhook when `payment-service` error rate exceeds threshold — blocked on `DD_API_KEY`

### 4.6 Docker Compose wiring
- [x] `devops-oversight-agent` service in `compose/docker-compose.yml` — builds from `../code/agent`, port mapped `8092:8000` (host 8092 avoids Colima AMP-VM port collision), health-checked on `/health`
- [x] `splunk-mock-mcp` service — port `8400:8400`
- [x] `datadog-mock-mcp` service — port `8401:8401`
- [x] All three MCP URL env vars wired; switching to live vendors is a `.env` change only
- [x] LLM backend env vars: `LLM_PROVIDER`, `OLLAMA_BASE_URL`, `OLLAMA_MODEL`, `ANTHROPIC_API_KEY`, `AGENT_MODEL`

### 4.7 Unit tests
- [x] Tests in `code/agent/tests/agent_test.bal` — all passing
  - `buildInvestigationPrompt` includes service/severity/description/alertId
  - `SYSTEM_PROMPT` mentions all three MCPs and includes propose-before-act guardrail
  - `splitOnFirst` happy path, double separator, not-found error
  - `envOrCfg` fallback
  - **Test count note:** 19 tests as of Phase 4 §4.9 (up from the original 8, then ~12 pre-§4.9) — verify with `cd code/agent && bal test`; if `README.md`/`CLAUDE.md` cite an older figure, treat this file as authoritative and update them in the Phase 5 §5.6 doc pass.
- [ ] **[propose-before-act not test-covered]** No test currently asserts that the agent code rejects a `run_runbook` call made without a prior `list_runbooks`. Add a unit test once the code-level gate (§4.4 above) is implemented.

### 4.8 WSO2 Agent Manager deployment (optional — not blocking for demo)
Agent Manager's Python auto-instrumentation init container (`amp-python-instrumentation-provider`) does not apply to Ballerina. Ballerina's `observabilityIncluded = true` flag provides equivalent OTel traces natively. Agent Manager can still host the Ballerina agent container if desired.

- [ ] Create a Project in `amp-console`
- [ ] Create an Internal Agent definition pointing at `devops-poc/devops-oversight-agent:latest`
- [ ] Configure secrets: `ANTHROPIC_API_KEY`, MCP URLs, `DD_SITE`, `SPLUNK_HEC_TOKEN`
- [ ] Deploy and verify pod starts; confirm `/health` returns 200
- [ ] Trigger an investigation; confirm traces appear in `amp-trace-observer`

### 4.9 Skills endpoints, generalized discovery, configurable max turns (2026-07)
- [x] `SYSTEM_PROMPT` (`code/agent/prompts.bal`) broadened: "ALWAYS call discover_tools before using any Splunk or Datadog tool" → "...any non-topology__ tool" (applies uniformly to every federated backend, not just the original two); added discover_tools example queries for kubernetes/APIM/MI/IS
- [x] `code/agent/devops_oversight_agent.bal`: `newProxyClient()` helper — connects + completes the initialize handshake but skips `tools/list` (these endpoints call one known tool name directly, no use for the LLM loop's full seed-tool manifest)
- [x] `GET /health-report?product=` and `GET /top5?product=&count=` — call `topology__health_report`/`topology__top_issues` directly via `mcpCallTool`, **no LLM loop**. Verified live (Test 11): the endpoint answers correctly even with no LLM credentials configured, since `init()`'s failed LLM-readiness check only logs a warning and never blocks the HTTP listener
- [x] Replaced both literal `maxTurns=30` call sites with `configurable int agentMaxTurns = 40` (env `AGENT_MAX_TURNS`, `envOrInt` in `obs.bal`) — more federated backends means more discovery turns. Do NOT reduce below 25
- [x] Chat-command shortcuts (closes the Phase 7 §7.5 deferral): `parseSkillCommand()` recognizes `Health` / `Health <product>` / `Top5` / `Top5 <N>` / `Top5 <product>` in `chat()` and bypasses the LLM loop entirely — same `topology__health_report`/`topology__top_issues` calls as the HTTP endpoints, rendered as a markdown table (`renderHealthReportTable`/`renderTopIssuesTable`). **Verified live**: `POST /chat {"message":"Top5 3"}` and `{"message":"Health apim"}` both returned correct markdown tables against the running compose stack with zero LLM calls
- [x] Unit tests (`code/agent/tests/agent_test.bal`): `testAgentMaxTurnsDefaultIsFortyOrMore`, `testEnvOrIntFallback`, `testSystemPromptGeneralizesBeyondSplunkDatadog`, `testBuildHealthReportArgsEmptyWhenNoProduct`/`IncludesProduct`, `testBuildTopIssuesArgsDefaults`/`IncludesCountAndProduct`, `testParseSkillCommand*` (5 tests), `testRenderHealthReportTable*`/`testRenderTopIssuesTable*` (3 tests) — 27 agent tests total, all passing
- [x] Integration: Test 11 in `tests/runDockerConfigTests.sh` — starts `devops-oversight-agent`, `curl -sf "http://localhost:8092/top5?count=3"` returns an `issues` array — **verified green**

## Pitfalls

- **MCP init failures are non-fatal**: if a mock MCP is down at startup, the agent logs a warning and continues with the tools from the remaining servers. The investigation will degrade gracefully rather than crashing.
- **Tool name collisions**: if Splunk and Datadog both expose a tool called `search_logs`, the prefix namespace (`splunk__` vs `datadog__`) prevents collision. Anthropic tool names must be unique across the full list.
- **Max tokens vs max turns**: the agent loop exits on `end_turn` or after `maxTurns` turns (**(4.9)** configurable via `AGENT_MAX_TURNS`, default 40 as of Phase 6's backend expansion; do not reduce below 25). If an investigation hits the limit it returns "Investigation incomplete — max turns reached"; retry once before switching providers. A very detailed investigation may require increasing `max_tokens` or `maxTurns`.
- **Swapping to live vendor MCPs**: Datadog MCP (`mcp.datadoghq.com`) uses OAuth or API+APP key headers — the mock uses a bearer token. The `mcp_client.bal` auth header will need to be parameterized when switching.

## Deliverables

- [x] `code/agent/` — Ballerina agent package, builds clean, unit tests passing (see §4.7 for current count)
- [x] `code/mcp/splunk-mock-mcp/` — 5 tools, 8 tests passing
- [x] `code/mcp/datadog-mock-mcp/` — 7 tools, 11 tests passing
- [x] All three services wired into `compose/docker-compose.yml`
- [x] **(4.9)** `GET /health-report` and `GET /top5` skill endpoints — LLM-free, verified live against the compose stack (integration Test 11)
- [ ] End-to-end investigation test: `POST /investigate` against the live mesh → agent calls all three MCPs, proposes `disable-chaos`, returns a coherent summary
- [ ] A recorded agent trace in `amp-trace-observer` (if Agent Manager deployment done)

## Exit criteria

`POST /investigate { service: "payment-service", severity: "P1", description: "502 spike" }` → the agent calls at least one tool from each of the three MCPs, proposes the `disable-chaos` runbook, and returns a summary containing the trace_id, involved services, and Splunk + Datadog evidence links. Observable end-to-end without live vendor credentials (mocks satisfy the exit criterion).
