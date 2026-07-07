# Phase 0 — Prerequisites & Decisions

**Goal:** toolchain ready, dependencies pinned, decisions locked.

## Tasks

- [x] 0.1 Python 3.12 + `uv` installed; `code/` is a uv workspace (`uv sync`).
- [x] 0.2 Dependencies pinned: `a2a-sdk[http-server]>=1.1,<2`, `langchain>=1.0,<2`,
      `langgraph>=1.0,<2`, `langchain-mcp-adapters>=0.1`, `mcp>=1.9,<2`,
      `langchain-anthropic/-openai/-ollama`, `fastapi`, `uvicorn`, `httpx`,
      `asyncpg`, `redis`, `nats-py`, `opentelemetry-*`.
- [x] 0.3 Decisions locked (see [`../decisions.md`](../decisions.md) and
      [`../CLAUDE.md`](../CLAUDE.md)): LangChain `create_agent`; official `a2a-sdk`
      (not `python-a2a`); FastMCP mocks; hard interrupt gate; in-process topology
      tools; 1-prefixed host ports (side-by-side with the Ballerina stack).
- [x] 0.4 Docker available for the compose stack.

## Exit criteria

- [x] `cd code && uv sync` resolves cleanly.
- [x] `./tests/runUnitTests.sh` runs (green once later phases land).
