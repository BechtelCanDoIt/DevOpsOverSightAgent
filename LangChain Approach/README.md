# DevOps Observability POC — LangChain / A2A

A LangChain-native Python implementation of the DevOps Observability POC: an
orchestrator agent correlates signals across **Splunk** and **Datadog** to
diagnose incidents in a 7-service retail mesh, then proposes remediation behind
a hard human-approval gate. It is the sibling of the Ballerina
[`MCP Best Practices Approach`](../MCP%20Best%20Practices%20Approach/) — same
mesh, same 5-minute chaos demo, **a different agent architecture**.

## What's different here

- **Three agents over A2A.** `DevOpsOverSightAgent` (orchestrator) delegates to
  `DataDogAgent` and `SplunkAgent` over the **A2A protocol**. Each specialist
  reaches its platform through a dedicated **MCP client** talking to a mock MCP
  server. The Ballerina MCP Proxy (lazy-loading / `discover_tools`) is gone —
  low-context is achieved by **agent decomposition**: each specialist owns only
  its own small tool set, and the orchestrator's context never holds the vendor
  tool manifests.
- **Hard propose-before-act gate.** Where the Ballerina agent enforced approval
  in the prompt only, this orchestrator uses a LangGraph `HumanInTheLoop`
  interrupt: the graph physically pauses before `run_runbook` and only resumes
  after an operator approves.
- **Runs side-by-side** with the Ballerina stack — every host port is 1-prefixed.

See [`architecture/architecture.md`](architecture/architecture.md) for the deep
dive and [`todo/README.md`](todo/README.md) for the phase-by-phase build.

## Components

### Agent tier (`code/agent/`)

| Component | Package | Port (host) | Role |
|---|---|---|---|
| DevOpsOverSightAgent | `devops_oversight_agent` | 18092 → 8000 | Orchestrator: FastAPI surface, A2A delegate tools, 11 in-process topology tools, the approval gate |
| DataDogAgent | `datadog_agent` | 18101 → 8101 | A2A server wrapping a LangChain agent over the Datadog MCP client |
| SplunkAgent | `splunk_agent` | 18102 → 8102 | A2A server wrapping a LangChain agent over the Splunk MCP client |
| oversight_common | `oversight_common` | — | Shared kit: LLM factory, token CSV callback, OTel, config/Timeout-Chain, A2A server + base MCP client |

### Mock MCP servers (`code/mcp/`)

| Component | Package | Port | Tools |
|---|---|---|---|
| datadog-mock-mcp | `datadog_mock_mcp` | 18401 → 8401 | 8 (metrics, traces, spans, monitors, logs, error-tracking, dashboards) |
| splunk-mock-mcp | `splunk_mock_mcp` | 18400 → 8400 | 4 (`splunk_run_query`, `get_indexes`, `get_knowledge_objects`, `describe_query`) |

FastMCP streamable-HTTP servers serving verbatim fixtures keyed to the demo
trace id `abc123def456789012345678deadbeef`. Swap to live vendor MCPs by
pointing `DATADOG_MCP_URL` / `SPLUNK_MCP_URL` at them (plus auth headers) — no
code change.

### Mesh (`code/generate/`)

Seven FastAPI services + a load generator, plus the shared `mesh_common` kit
(chaos injection, structured logging, OTel, dual-listener runner, lazy infra
clients, W3C traceparent helpers).

| Service | Business (host) | Chaos (host) | Notes |
|---|---|---|---|
| store-service | 19091 | 19191 | catalog; enriches detail from inventory |
| customer-service | 19092 | 19192 | Postgres; seeds customers 1–5 |
| order-service | 19093 | 19193 | checkout saga; publishes `orders.created` (NATS) |
| inventory-service | 19094 | 19194 | Redis read-through → Postgres |
| invoice-service | 19095 | 19195 | issued → paid state machine |
| payment-service | 19096 | 19196 | stateless mock; **headline chaos target** |
| notification-service | 19097 | 19197 | NATS subscriber; async trace-join to Splunk |
| load-gen | — | — | baseline / spike / regression traffic patterns |

Every service exposes `GET /health` (never chaos-gated) on :9090 and the chaos
API (`/chaos/latency\|error\|reset`, `X-Chaos-Token`) on :9099.

### Infra

OTel Collector (host 14317/14318), Postgres (15432), Redis (16379), NATS
(14222/18222); optional Jaeger (`--profile dev`, 26686) and Datadog Agent
sidecar (`--profile saas`).

## How A2A works

The orchestrator does **not** hold the Datadog and Splunk tools itself. It treats
"the Datadog team" and "the Splunk team" as separate agents and **delegates** to
them over the **A2A (Agent-to-Agent) protocol**. This is the deliberate
counterpart to the Ballerina MCP Proxy: A2A sits at the **platform-team
boundary**, *not* inside correlation. Each specialist eagerly loads only its own
small MCP tool set, so the vendor tool manifests never enter the orchestrator's
context — yet the orchestrator stays the single reasoning context that *fuses*
the evidence both specialists return.

Transport is **JSON-RPC over HTTP**; agents advertise `streaming=True`. The SDK
is the official **`a2a-sdk` (`>=1.1,<2`)** — protobuf-based, so the 0.2.x blog
tutorials do **not** apply; build against the installed package.

### The three moving parts

1. **Agent cards.** Each specialist publishes an `AgentCard` at the well-known
   path `/.well-known/agent-card.json` — its name, its one `AgentSkill`
   (`datadog_evidence` / `splunk_log_search`), capabilities, and its JSON-RPC
   endpoint URL. This is how the orchestrator discovers what a specialist can do.
2. **The specialist server.** `DataDogAgent` (`:8101`) and `SplunkAgent`
   (`:8102`) are each a LangChain ReAct agent wrapped as an A2A server. On an
   incoming message they run their own reasoning loop against their MCP backend
   and return a single text reply.
3. **The orchestrator client.** At startup the orchestrator resolves both cards
   and builds one A2A client per specialist. Two LangChain `@tool`s —
   `ask_datadog_agent` and `ask_splunk_agent` — are what the orchestrator's LLM
   calls; each sends one A2A message and returns the specialist's text.

Delegation is **one-way** (orchestrator → specialist) and **request/response** —
a single round-trip, no long-running A2A `Task` lifecycle. Evidence crosses the
boundary as **prose**, so the specialist prompts mandate returning concrete
values, timestamps, and any `trace_id` **verbatim** — a vague reply starves the
orchestrator's correlation, which is the quiet bottleneck of this shape.

### A delegation call, end to end

```text
orchestrator LLM
  → ask_datadog_agent("error rate + a sample trace_id for payment-service")   # @tool
  → _ask("datadog", request)
      → SendMessageRequest(new_text_message(request, role=ROLE_USER))
      → client.send_message(req)                     # A2A JSON-RPC POST → :8101
DataDogAgent  (A2A server)
  → LangChainAgentExecutor.execute(context, event_queue)
      → context.get_user_input()
      → agent.ainvoke({messages:[HumanMessage(request)]})   # ReAct loop → Datadog MCP
      → enqueue new_text_message(final_text, role=ROLE_AGENT)
orchestrator
  ← get_stream_response_text(resp)  →  tool result  →  LLM continues correlating
```

### Implementation map

| Concern | Where |
|---|---|
| Server machinery (card, executor, app, run) | `oversight_common/a2a_server.py` — `build_agent_card`, `LangChainAgentExecutor`, `build_a2a_app`, `run_a2a_agent` |
| Specialist boot + skill/card | `datadog_agent/__main__.py`, `splunk_agent/__main__.py` (eager MCP load → `create_agent` → `run_a2a_agent`) |
| Client (resolve cards, delegate tools) | `devops_oversight_agent/a2a_clients.py` — `init_a2a_clients`, `_ask`, `ask_datadog_agent`, `ask_splunk_agent` |
| Wiring into the orchestrator | `devops_oversight_agent/main.py` (resolves clients at startup) + `agent.py` (tool set includes `A2A_DELEGATE_TOOLS`) |

Robustness details worth knowing:

- **Start order is forgiving** — `init_a2a_clients` retries card resolution
  (10× / 2s), so the orchestrator tolerates a specialist that is still booting.
- **A specialist never crashes the server** — `LangChainAgentExecutor.execute`
  catches exceptions and returns them as agent text (`"investigation error: …"`).
- **The A2A rung of the Timeout Chain** is the shared `httpx` client timeout
  (`A2A_TIMEOUT_S=300`), which must nest inside uvicorn (600s) and outside the
  sub-agent LLM (180s) — see
  [architecture §6](architecture/architecture.md#6-the-timeout-chain).

Config (env vars, with defaults):

| Var | Default | Meaning |
|---|---|---|
| `DATADOG_AGENT_URL` / `SPLUNK_AGENT_URL` | `http://datadog-agent:8101` / `http://splunk-agent:8102` | where the orchestrator resolves each card |
| `DATADOG_AGENT_PORT` / `SPLUNK_AGENT_PORT` | `8101` / `8102` | the port each specialist serves on |
| `A2A_TIMEOUT_S` | `300` | A2A client timeout (Timeout-Chain rung) |

## Getting started

```bash
cd "LangChain Approach"

# Unit tests (no Docker, no infra needed)
./tests/runUnitTests.sh

# Full stack (creds-free; mock MCPs + debug collector)
make demo-up

# Drive the headline demo
./demo/inject-chaos.sh payment-service 0.8 2000 300
make investigate                       # returns a proposal + sessionId
curl -s -X POST http://localhost:18092/chat -H 'Content-Type: application/json' \
  -d '{"message":"approve","sessionId":"<from the summary>"}'
make reset-chaos
```

LLM backend is configurable via `LLM_PROVIDER` (`anthropic` default, `ollama`
creds-free, `openai`, `amp`). See [`compose/.env.example`](compose/.env.example).

Development notes and locked decisions are in [`CLAUDE.md`](CLAUDE.md);
gotchas in [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md).
