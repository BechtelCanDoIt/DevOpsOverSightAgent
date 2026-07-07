# Sequence — Incident triage (beat level)

The 5-minute demo, as a sequence. Message-level A2A detail is in
[`sequence-a2a-delegation.md`](sequence-a2a-delegation.md).

```
Operator        Orchestrator        DataDogAgent     SplunkAgent      Mesh (payment)
   │                 │                   │                │                │
   │ inject-chaos.sh ──────────────────────────────────────────────────►  │  chaos armed
   │                 │                   │                │                │
   │ POST /investigate                   │                │                │
   ├────────────────►│                   │                │                │
   │                 │ ask_datadog_agent (monitors, metrics, trace_id)     │
   │                 ├──────────────────►│  MCP tools → datadog-mock-mcp   │
   │                 │◄──────────────────┤  "monitor ALERT; err 0.02→0.31; trace abc123…"
   │                 │ topology__correlate_trace(abc123…)  (in-process)    │
   │                 │   → Datadog URL + Splunk SPL + involved services     │
   │                 │ ask_splunk_agent (run SPL)          │                │
   │                 ├────────────────────────────────────►│ MCP → splunk-mock-mcp
   │                 │◄────────────────────────────────────┤ "6 events, payment 502, no deploys"
   │                 │ topology__get_dependencies / find_recent_deploys / find_related_incidents
   │                 │   no recent deploy + payment 502 → CHAOS heuristic  │
   │                 │ topology__list_runbooks → propose disable-chaos      │
   │                 │ topology__run_runbook  ── ⛔ HumanInTheLoop interrupt │
   │◄────────────────┤  {status:investigated, summary: PROPOSAL, sessionId}│
   │                 │                   │                │                │
   │ POST /chat {approve, sessionId}     │                │                │
   ├────────────────►│  Command(resume=approve) → graph resumes            │
   │                 │ run_runbook disable-chaos ─ POST /chaos/reset ─────► │  chaos cleared
   │◄────────────────┤  {message: remediated + postmortem}                 │
   │ probe /charge ─────────────────────────────────────────────────────► │  201 approved
```

Key points:
- Steps between the two `/investigate`/`/chat` calls all share one OTel trace
  (httpx propagates `traceparent` across A2A and MCP hops).
- The interrupt is the hard gate: `run_runbook` does not execute until the
  `approve` resume arrives on the same `sessionId`.
- A `reject` (or any non-approval reply) resumes the graph with the runbook
  **not** executed; the agent adjusts and summarizes.
