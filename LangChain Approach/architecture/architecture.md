# Architecture — LangChain / A2A DevOps Observability POC

This is the deep dive. For the component catalog and quick-start see
[`../README.md`](../README.md); for the build sequence see
[`../todo/README.md`](../todo/README.md).

## 1. The thesis

Observability data lives in silos — Splunk for logs, Datadog for metrics and
APM. During an incident an engineer swivel-chairs between them, manually
correlating by trace id. This POC automates that correlation, proposes a fix,
and executes an approved runbook — with a mandatory human approval gate before
any change.

The **reference** (Ballerina) implementation puts the whole correlation core in
one process behind a single MCP Proxy. **This** implementation demonstrates the
same incident triage with a multi-agent topology over A2A, deliberately to show
the trade-offs.

## 2. Topology

```
User / Datadog webhook
   │  POST /chat | /investigate | /webhook/alert   (FastAPI :8000, host 18092)
   ▼
DevOpsOverSightAgent  (LangChain create_agent on the LangGraph runtime)
   │  tools:
   │    ask_datadog_agent / ask_splunk_agent   ── A2A (JSON-RPC) ──┐
   │    topology__*  (11 in-process tools: catalog, correlate_trace,│
   │                  deploys, incidents, runbooks, audit)          │
   │  HumanInTheLoop gate: interrupt before topology__run_runbook   │
   ├───────────────────────────────────────────────────────────────┤
   ▼                                                                ▼
DataDogAgent (:8101)                                     SplunkAgent (:8102)
   │ DataDogMCPClient                                       │ SplunkMCPClient
   │ (langchain-mcp-adapters, streamable-http)              │ (same)
   ▼                                                        ▼
datadog-mock-mcp (:8401 /mcp, FastMCP)          splunk-mock-mcp (:8400 /mcp, FastMCP)

Mesh (observed & remediated): store, customer, order, inventory, invoice,
payment, notification + load-gen. All emit OTLP to one Collector; the agents
emit to the same Collector, so one trace spans user → orchestrator → A2A →
specialist → MCP → mock.
```

## 3. Why this shape (design decisions)

- **Correlation stays in one reasoning context.** The orchestrator is the
  single place that fuses Datadog + Splunk + topology evidence. A2A is used only
  at the *platform-team boundary* (a Datadog team, a Splunk team) — not to split
  the correlation itself. This mirrors the reference's "A2A at the org boundary,
  not the correlation core" principle, now demonstrated live.
- **The MCP Proxy dissolves into three responsibilities.** Federation + prefix
  routing → the A2A boundary (delegate by skill, not tool prefix). Lazy loading
  / `discover_tools` → structural: the vendor tool manifests never enter the
  orchestrator's context at all; each specialist eagerly loads only its own
  small tool set (8 Datadog / 4 Splunk). Topology / correlation / runbooks →
  in-process orchestrator tools, keeping `run_runbook` in the same trust domain
  as the human-approval gate.
- **The approval gate is code-level, not prompt-level.** `HumanInTheLoopMiddleware`
  interrupts the graph before `topology__run_runbook`; an `InMemorySaver`
  checkpointer keys the paused state by `sessionId`. `/investigate` returns the
  proposal + a `sessionId`; the operator approves via `/chat`, which resumes with
  `Command(resume={"decisions":[{"type":"approve"}]})`. An unrecognized reply is
  treated as a rejection — the gate is fail-safe.

## 4. Telemetry fan-out

One OTel Collector receives OTLP from every mesh service **and** all three
agents, and fans out (SaaS overlay): traces → Datadog + Splunk, logs → Splunk
(HEC), metrics → Datadog. The join key is `trace_id`, present in both platforms.
`httpx` auto-instrumentation propagates W3C `traceparent` across every HTTP hop
— including the A2A calls and the MCP streamable-HTTP calls — so a single trace
covers the whole investigation. The async order→notification leg is joined
manually: order publishes a `traceparent` in the NATS envelope, notification
parses it and logs with the extracted `trace_id` (the Splunk async-leg join).

Deliberate deviations from the Ballerina telemetry (all documented so a reader
of both stacks isn't surprised):

1. **OTLP-push metrics** instead of a Prometheus `:9797` scrape — the scrape and
   the `transform/servicename` processor were Ballerina-runtime artifacts; the
   Python SDK sets `service.name` correctly at source.
2. **OTLP logs pipeline** instead of the `filelog` receiver (which is
   non-functional on macOS Docker Desktop).

## 5. The trace-id gotcha (CRITICAL)

Datadog emits a 64-bit `dd.trace_id`; OTel and Splunk hold the 128-bit
`otel.trace_id`. Building a Splunk query from a 64-bit id (or a Datadog URL from
a 128-bit id) returns nothing. `correlation.normalize_trace_id()` left-pads a
16-hex id to 32-hex (the low-64 bits of the 128-bit id) for Splunk, and
`to_datadog_64()` takes the low-16-hex for the Datadog APM URL. All correlation
goes through these. The mocks use the same 32-hex demo id everywhere, so their
8-char-prefix matching masks the problem — **live-backend wiring must go through
`normalize_trace_id`**, and there are regression tests for both widths.

## 6. The Timeout Chain

A cross-process failure mode: if an inner timeout outlives an outer one, the
orchestrator sees opaque A2A errors mid-investigation. The chain is strictly
ordered, largest outermost — uvicorn 600s > A2A client 300s > sub-agent LLM
180s > MCP call 30s — and `oversight_common.config.assert_timeout_chain()` fails
fast at orchestrator startup if it is misordered.

## 7. Remediation flow (headline demo)

1. Operator injects chaos on payment-service (80% 502 + 2s latency).
2. `POST /investigate {service:payment-service, severity:P1}`.
3. Orchestrator delegates to DataDogAgent (monitors → metrics → a sample
   `trace_id`), calls `topology__correlate_trace` locally, delegates the SPL to
   SplunkAgent, checks dependencies / deploys / incidents.
4. No recent deploy + payment 502 → chaos heuristic → propose `disable-chaos`.
   **The gate interrupts.** `/investigate` returns the proposal + `sessionId`.
5. Operator approves via `/chat` → graph resumes → `disable-chaos` POSTs
   `/chaos/reset` on payment-service → recovery confirmed.

One OTel trace spans steps 2–5. See
[`sequence-a2a-delegation.md`](sequence-a2a-delegation.md) for the message-level
trace and [`sequence-overview.md`](sequence-overview.md) for the beat-level view.

## 8. Known gotchas

See [`../KNOWN_ISSUES.md`](../KNOWN_ISSUES.md). Highlights: a2a-sdk v1.x is
protobuf-based (pin `>=1.1,<2`; ignore 0.2.x blog tutorials); Ollama
tool-calling non-determinism is now multiplied across three agents (keep
`MAX_TURNS=30`); sub-agent answer quality is the correlation bottleneck (the
specialist prompts' output contract — always return trace_ids/values/timestamps
— is load-bearing); in-memory state (audit log, deploy-freeze, LangGraph
checkpoints, A2A task store) is lost on restart, including a pending approval.

## 9. Production path

Same core shape, four changes (unchanged from the reference's enterprise
section): service catalog from a real CMDB (not the static map in `catalog.py`);
identity/secrets via OIDC/SSO + a vault (not env vars); remediation in a
separate trust domain with GitOps/change tickets (not in-process runbooks);
A2A kept at the org boundary. Still MCP-based, still propose-before-act, still
one reasoning context for correlation.
