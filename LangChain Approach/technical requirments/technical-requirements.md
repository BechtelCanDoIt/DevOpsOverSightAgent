# Technical Requirements — DevOps Observability POC (LangChain / A2A)

A specification of what this implementation provides. It mirrors the sibling
Ballerina requirements but pins the multi-agent A2A architecture. Requirement
IDs use FR (functional) / NFR (non-functional).

## Business goals

- **G1** Reduce MTTR for P1/P2 incidents via automated cross-platform correlation. [CRITICAL]
- **G2** Enforce a human-approval gate before any remediation. [CRITICAL]
- **G3** Single investigation interface — no manual context-switching between Splunk and Datadog. [HIGH]
- **G4** Vendor flexibility — no LLM lock-in. [HIGH]
- **G5** Agent self-observability through the same telemetry pipeline. [HIGH]
- **G6** Full incident cycle demonstrable offline in ~5 minutes. [MEDIUM]

Headline use case (UC-1): payment-service chaos → investigate → identify root
cause → propose disable-chaos → operator approves → remediate → recover.

## Functional requirements

### Orchestrator (DevOpsOverSightAgent)

- **FR-1** Expose HTTP: `GET /health`, `POST /chat {message, sessionId?, conversationId?}`,
  `POST /investigate {service, severity, description, id}`, `POST /webhook/alert`
  (Datadog-style, `title` fallback). Responses byte-compatible with the reference.
- **FR-2** Delegate Datadog evidence to DataDogAgent and Splunk evidence to
  SplunkAgent **over A2A**; fuse the results in one reasoning context.
- **FR-3** Provide 11 in-process topology tools: lookup_service, list_services,
  get_dependencies, get_service_health, correlate_trace, find_recent_deploys,
  find_related_incidents, list_runbooks, run_runbook, get_audit_log,
  get_deploy_freeze_status.
- **FR-4** `correlate_trace` MUST normalize between 64-bit (Datadog) and 128-bit
  (Splunk) trace ids and return a Datadog APM URL, Splunk SPL + search URL, and
  the involved services.
- **FR-5** Propose-before-act: the graph MUST NOT execute `run_runbook` without
  explicit human approval. `/investigate` returns the proposal + a `sessionId`;
  approval arrives via `/chat` on that session. A non-approval reply MUST NOT
  execute the runbook.
- **FR-6** Four runbooks: restart-service (stub), clear-cache (Redis stub),
  disable-chaos (POST `/chaos/reset` on the target), freeze-deploys (audit flag).
- **FR-7** Follow the 10-step investigation protocol; apply the payment-502 +
  no-recent-deploy ⇒ chaos heuristic.

### Specialist agents (A2A)

- **FR-8** DataDogAgent and SplunkAgent each publish an A2A AgentCard (skill,
  streaming) at the well-known path, and answer `message/send` by running a
  LangChain agent over their MCP client.
- **FR-9** Each loads only its own platform's MCP tools (8 Datadog / 4 Splunk),
  eagerly at startup with retry. Specialists are READ-ONLY.
- **FR-10** Specialist replies MUST include any trace_id verbatim plus concrete
  values, timestamps, and states (the cross-boundary evidence contract).

### Mock MCP servers

- **FR-11** Splunk mock: 4 tools with the exact reference names/args/result JSON
  and the `filter_events` heuristic (trace-id 8-char prefix; 502/error →
  status>=400 with empty-fallback). Datadog mock: 8 tools likewise.
- **FR-12** Both serve verbatim fixtures keyed to demo trace id
  `abc123def456789012345678deadbeef`; swappable for live MCPs by URL + auth env.

### Mesh

- **FR-13** 7 services with the reference endpoints, status mappings, seeds, ID
  formats, and log message texts. order-service runs the checkout saga
  (customer 404→400, stock→409, payment/invoice→502, db→500/503; UNIT_PRICE 19.99;
  order id `ORD-{ms}-{4digit}`).
- **FR-14** Chaos API on :9099 (`/chaos/latency|error|reset`, `X-Chaos-Token`);
  `/health` never gated; latency-then-error ordering.
- **FR-15** Async trace-join: order publishes a W3C `traceparent` in the NATS
  `orders.created` envelope; notification parses it and logs with the extracted
  trace_id.
- **FR-16** load-gen drives baseline/spike/regression patterns.

## Non-functional requirements

- **NFR-1** LLM provider swappable via `LLM_PROVIDER` (anthropic/ollama/openai/amp),
  no code change; readiness probe never crashes the agent.
- **NFR-2** Self-observability: all mesh services and all agents emit OTLP to one
  Collector; W3C context propagates across HTTP, A2A, and MCP hops so one trace
  spans an investigation.
- **NFR-3** Timeout Chain strictly ordered (uvicorn > A2A > LLM > MCP), asserted
  at startup.
- **NFR-4** Per-turn token/timing capture in the reference CSV shape, gated by
  `CSV_MCP_PROXY`.
- **NFR-5** Unit tests run infra-free (`uv run pytest`); the stack runs
  side-by-side with the Ballerina stack (1-prefixed host ports).
- **NFR-6** Turn budget `MAX_TURNS=30` (floor 25) → LangGraph `recursion_limit`.

## Out of scope (POC)

Real CMDB integration, OIDC/SSO + vault secrets, a separate remediation trust
domain with GitOps, and persistence of audit/checkpoint state — all noted as the
production path in `architecture/architecture.md` §9.
