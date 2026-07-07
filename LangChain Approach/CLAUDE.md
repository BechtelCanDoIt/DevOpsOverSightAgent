# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is the **LangChain-native Python** implementation of the **DevOps Observability POC**: an orchestrator agent (**DevOpsOverSightAgent**) correlates signals across **Splunk** and **Datadog** by delegating to two specialist agents (**DataDogAgent**, **SplunkAgent**) over the **A2A protocol**; each specialist reaches its platform through a dedicated **MCP client** talking to a mock MCP server. The sibling `MCP Best Practices Approach/` folder holds the reference Ballerina implementation this port mirrors — same mesh, same chaos demo, different agent architecture.

**Read these first — they are the canonical docs. Do not duplicate their content here; update them and link.**

- [`README.md`](README.md) — component catalog: every service, the two mock MCP servers, and the three agents, plus getting-started.
- [`architecture.md`](architecture/architecture.md) — deep dive: A2A topology, telemetry fan-out, cross-system correlation, the remediation flow, design decisions (incl. why the MCP Proxy dissolved), and known gotchas.
- [`todo/README.md`](todo/README.md) → [`todo/phase-0..5`](todo/) — the **authoritative**, phase-by-phase implementation specs and exit criteria.

## Source layout

- `code/` — a single **uv workspace** (Python 3.12), split into three sub-directories:
  - `agent/` — `devops_oversight_agent/` (orchestrator, FastAPI :8000), `datadog_agent/` + `splunk_agent/` (a2a-sdk servers :8101/:8102), `oversight_common/` (LLM factory, token CSV, OTel).
  - `mcp/` — `splunk_mock_mcp/` (FastMCP :8400, 4 tools) and `datadog_mock_mcp/` (FastMCP :8401, 8 tools).
  - `generate/` — 7 FastAPI mesh services + `load_gen/` + `mesh_common/` (shared chaos/obs/telemetry kit).
- `compose/` — Docker Compose stack · `demo/` — demo scripts · `todo/` — phase specs.

## Locked Decisions

- **Language/stack:** **Python 3.12 + LangChain** (this folder deliberately diverges from the Ballerina sibling — that is the point of the comparison).
- **Agent framework:** LangChain 1.x `create_agent` (LangGraph runtime) for all three agents. Orchestrator adds `HumanInTheLoopMiddleware` + `InMemorySaver` for the **hard propose-before-act gate**: the graph physically interrupts before `topology__run_runbook`; the operator approves via `/chat` on the returned `sessionId`.
- **A2A:** official `a2a-sdk` (a2aproject/a2a-python), pinned `>=1.1,<2`. Do **not** use the third-party `python-a2a` package — different, incompatible API.
- **MCP:** official `mcp` SDK. Mocks are FastMCP streamable-HTTP servers at `/mcp`; agents use named `DataDogMCPClient`/`SplunkMCPClient` classes over `langchain-mcp-adapters`. No MCP Proxy, no `discover_tools` — low-context is achieved by agent decomposition (each sub-agent owns only its platform's tools).
- **LLM:** configurable via `LLM_PROVIDER` env var — all providers in `code/agent/oversight_common/llm_factory.py`:
  - `anthropic` (default) — `ChatAnthropic`; AMP proxy via `ANTHROPIC_URL`; requires `ANTHROPIC_API_KEY`; model via `AGENT_MODEL` (default `claude-sonnet-4-6`, parity with the Ballerina stack)
  - `ollama` — `ChatOllama`; creds-free; default model `qwen2.5:14b-instruct` at `OLLAMA_BASE_URL` (the qwen2.5 family is the most reliable open tool-caller at this size; qwen3.5:9b works but stalls on long protocols)
  - `openai` — `ChatOpenAI`; override endpoint with `OPENAI_BASE_URL`; requires `OPENAI_API_KEY`
  - `amp` — WSO2 AMP AI gateway (OpenAI-compatible); AMP injects `LLM_BASE_URL` + optional `LLM_API_KEY`; set `LLM_MODEL`
- **Telemetry:** OTel Python SDK, OTLP push to this stack's own Collector (`14317`/`14318` on the host). Deliberate deviations from the Ballerina stack: OTLP-push metrics (no Prometheus :9797 scrape), OTLP logs pipeline (no filelog receiver).
- **Mesh:** same hybrid 7-service retail mesh + `load_gen`; identical chaos contract (`/chaos/latency|error|reset` on :9099, `X-Chaos-Token`).
- **Mock MCPs:** `splunk-mock-mcp` (container :8400, host :18400) and `datadog-mock-mcp` (container :8401, host :18401); swapped for live vendor MCPs via `SPLUNK_MCP_URL`/`DATADOG_MCP_URL` with no code changes.
- **Ports:** this stack is **side-by-side runnable** with the Ballerina stack — every host port gets a `1` prefix (chaos 19191–19197, agent 18092, OTLP 14317, postgres 15432, …). Container ports are unchanged.
- **Agent turn budget:** `MAX_TURNS=30` (mapped to LangGraph `recursion_limit = 2*MAX_TURNS+1`; do NOT reduce below 25 — Ollama non-determinism).

## Commands

```bash
# Everything runs from this folder ("LangChain Approach/")

# Dependency setup (uv workspace)
cd code && uv sync

# Unit tests (infra-free; DB/Redis/NATS clients are lazy + injectable)
./tests/runUnitTests.sh            # == cd code && uv run pytest

# Compose stack (creds-free default; mocks + debug exporter)
docker compose -f compose/docker-compose.yml up -d
docker compose -f compose/docker-compose.yml ps

# Trigger an investigation (agent published on 18092)
curl -X POST http://localhost:18092/investigate \
  -H "Content-Type: application/json" \
  -d '{"service":"payment-service","severity":"P1","description":"502 spike"}'

# Approve a proposed runbook (sessionId comes back in the /investigate summary)
curl -X POST http://localhost:18092/chat \
  -H "Content-Type: application/json" \
  -d '{"message":"approve","sessionId":"inv-..."}'

# Inject chaos into payment-service (host chaos port 19196)
curl -X POST http://localhost:19196/chaos/error \
  -H "X-Chaos-Token: dev-chaos-token" -H "Content-Type: application/json" \
  -d '{"rate": 0.8, "status": 502, "duration_s": 300}'
curl -X POST http://localhost:19196/chaos/latency \
  -H "X-Chaos-Token: dev-chaos-token" -H "Content-Type: application/json" \
  -d '{"ms": 2000, "duration_s": 300}'
curl -X POST http://localhost:19196/chaos/reset -H "X-Chaos-Token: dev-chaos-token"

# Or use the demo scripts
./demo/inject-chaos.sh payment-service 0.8 2000 300
./demo/reset.sh

# MCP / A2A config tests (creds-free, compose-based)
./tests/runDockerConfigTests.sh
./tests/runA2AConfigTests.sh

# SaaS demo (requires DD_API_KEY, DD_SITE, SPLUNK_HEC_TOKEN, SPLUNK_HEC_URL, SPLUNK_INDEX in compose/.env)
docker compose -f compose/docker-compose.yml -f compose/docker-compose.saas.yml --profile saas up -d

# Demo orchestration
make demo-up / make demo-down / make rehearse
```

## Gotchas (port-specific)

- **Chaos latency must stay async** — `apply_chaos` uses `await asyncio.sleep(...)`; a `time.sleep` anywhere in a request path stalls the event loop and turns a 2s-latency demo into an outage.
- **Log field names are load-bearing** — Splunk correlation (mock and live) keys on `trace_id`, `span_id`, `service`, `status` and message texts like `"payment failed"`. Don't rename them.
- **Trace-ID width** — `correlation.py:normalize_trace_id()` handles the Datadog 64-bit vs OTel 128-bit mismatch. Any live-backend wiring must go through it (the mocks' 8-char-prefix matching masks the problem).
- **Timeout Chain** — uvicorn 600s > A2A client 300s > sub-agent LLM 180s > MCP call 30s. Asserted at orchestrator startup; keep it ordered.
- **a2a-sdk version drift** — most online tutorials cover 0.2.x; this repo pins `>=1.1,<2`. Verify API shapes against the installed package, not blogs.

## Phase Status

| Phase | Name | Status |
|-------|------|--------|
| 0 | Prerequisites & decisions | Complete — decisions locked (this file + `architecture.md`) |
| 1 | Docker Compose observability stack | See `todo/phase-1-compose.md` |
| 2 | Python service mesh + traffic generator | See `todo/phase-2-mesh.md` |
| 3 | Mock MCP servers | See `todo/phase-3-mcp.md` |
| 4 | Three agents + A2A | See `todo/phase-4-agent.md` |
| 5 | Demo rehearsal & verification | See `todo/phase-5-verify.md` |

Detailed exit criteria for each phase are in `todo/phase-<N>-*.md`.
