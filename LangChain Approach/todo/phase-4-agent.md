# Phase 4 — Three Agents + A2A

**Goal:** the two specialist agents over A2A and the orchestrator with the hard
propose-before-act gate.

## Tasks

- [x] 4.1 `oversight_common`: LLM factory (`anthropic`/`ollama`/`openai`/`amp`,
      same env contract), `check_llm_ready`, token CSV callback (identical shape),
      OTel setup, config + `assert_timeout_chain`, base MCP client, shared A2A
      server (`LangChainAgentExecutor`, `build_agent_card`, `run_a2a_agent`).
- [x] 4.2 `DataDogMCPClient` / `SplunkMCPClient` (named, over langchain-mcp-adapters,
      streamable-http, with the live-vendor auth-header hook).
- [x] 4.3 DataDogAgent + SplunkAgent: eager MCP tool load (retry), `create_agent`
      ReAct loop, AgentCard/skill, A2A JSON-RPC server, specialist prompts with
      the evidence output contract.
- [x] 4.4 Orchestrator: `catalog.py`, `correlation.py` (+ `normalize_trace_id`),
      `runbooks.py` (per-id locks, disable-chaos POSTs /chaos/reset), `audit.py`,
      11 `topology__*` tools, `a2a_clients.py` (card resolution + delegate tools),
      `prompts.py` (10-step protocol port), `agent.py` (graph + HumanInTheLoop +
      InMemorySaver), `main.py` (FastAPI: /health, /chat, /investigate, /webhook/alert).
- [x] 4.5 The gate: interrupt before `run_runbook`; approve via `/chat` on the
      returned `sessionId`; rejection never executes.
- [x] 4.6 Tests: A2A round-trip (stub agent), MCP client wiring, trace-id
      normalization, runbooks + audit, and the three gate tests.

## Exit criteria

- [x] `uv run pytest agent` green, incl. the A2A round-trip and the gate tests.
- [x] (On a Docker host, with an LLM) `POST /investigate` touches both specialists
      and topology tools and ends in a disable-chaos proposal (never auto-run);
      approving via `/chat` resets the chaos.
