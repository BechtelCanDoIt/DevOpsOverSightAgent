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
