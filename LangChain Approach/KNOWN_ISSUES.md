# Known Issues & Gotchas

Carried from the port design plus what surfaced building it. See
[`architecture/architecture.md`](architecture/architecture.md) for context.

## Agent tier

- **a2a-sdk is protobuf-based (v1.1).** The `>=1.1,<2` SDK uses protobuf
  message types (`AgentCard`, `Message`, `Part` have no `model_fields`) — the
  0.2.x pydantic API most blog tutorials show does not apply. Build messages
  with `a2a.helpers.proto_helpers` (`new_text_message`, `get_stream_response_text`);
  the executor enqueues a plain agent `Message` (no Task lifecycle). The
  round-trip is guarded by `oversight_common/tests/test_a2a_server.py`.
- **Ollama tool-calling non-determinism, now ×3.** The orchestrator must reliably
  emit the `ask_*` delegate calls **and** `topology__run_runbook` with structured
  args, and the resume adds another structured step. Keep `MAX_TURNS=30` (floor
  25); rehearse with the actual LLM early. Prefer `anthropic` for the live demo.
- **Sub-agent answer quality is the correlation bottleneck.** Evidence crosses
  the A2A boundary as prose; a vague specialist reply (missing trace_id/values/
  timestamps) starves the orchestrator. The specialist prompts' output contract
  is load-bearing — don't weaken it.
- **In-memory state is lost on restart.** Audit log, deploy-freeze flag, LangGraph
  `InMemorySaver` checkpoints, and the A2A `InMemoryTaskStore` are all in-memory
  (POC parity). A restart mid-approval silently drops a pending runbook proposal.
  Production persists these to a remediation trust domain.
- **Timeout Chain must stay ordered.** uvicorn 600s > A2A 300s > LLM 180s > MCP
  30s. `assert_timeout_chain()` fails fast at startup on misorder; don't relax it.

## Telemetry & correlation

- **Trace-id 64/128-bit (CRITICAL).** Datadog 64-bit vs OTel/Splunk 128-bit. All
  correlation goes through `correlation.normalize_trace_id`. The mocks use a
  single 32-hex demo id and 8-char-prefix matching, which **masks** the mismatch
  — live-backend wiring must exercise normalization (regression-tested both widths).
- **Log-field drift breaks Splunk silently.** The mock `filter_events` and real
  SPL key on `trace_id`, `service`, `status` and message texts like
  `"payment failed"`. Renaming a log field won't fail a unit test but will make
  the agent find zero evidence.
- **Live vendor MCP auth is unverified.** `DATADOG_MCP_HEADERS` / `SPLUNK_MCP_TOKEN`
  wire auth headers, but the live Datadog/Splunk MCP endpoints (session/rate
  behavior) are untested until creds arrive — don't claim live verified.

## Mesh & ops

- **Chaos latency must be async.** `apply_chaos` uses `await asyncio.sleep`; a
  `time.sleep` in a request path would stall the event loop and turn a 2s-latency
  demo into an outage.
- **Deliberate deviations from the Ballerina stack** (documented, not bugs):
  single `mesh_common` package (vs copy-per-service); OTLP-push metrics (no
  Prometheus :9797); OTLP logs (no filelog); lazy infra clients (pytest is
  infra-free); FastMCP (vs hand-rolled JSON-RPC); `uuid4` payment ids (vs uuid1);
  the `/chaos/error` `duration_s` fix; POST-create endpoints return 201.
- **Port collisions.** Host ports are 1-prefixed to coexist with the Ballerina
  stack, but 15432/16379 are common local Postgres/Redis alt-ports — `lsof -nP
  -iTCP:16379` if compose can't bind.
- **Docker healthchecks use Python, not curl.** The `python:3.12-slim` runtime has
  no curl/wget, so healthchecks call `python -c "import urllib.request; ..."`.
