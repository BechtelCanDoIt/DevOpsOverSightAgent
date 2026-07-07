# Decisions

Locked decisions for the LangChain/A2A port, with rationale. Companion to
[`CLAUDE.md`](CLAUDE.md) and [`architecture/architecture.md`](architecture/architecture.md).

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | **Language: Python 3.12 + LangChain**, `uv` workspace | The whole point of this folder — a LangChain-native counterpart to the Ballerina sibling. |
| D2 | **A2A: official `a2a-sdk` (a2aproject/a2a-python), pinned `>=1.1,<2`** | The POC demonstrates protocol best practice; a hand-rolled A2A would undercut it. The third-party `python-a2a` has an incompatible API — avoided. v1.1 is protobuf-based; build against the installed SDK, not 0.2.x tutorials. |
| D3 | **Agents: LangChain 1.x `create_agent` (LangGraph runtime)** for all three | Modern high-level ReAct API; the orchestrator layers `HumanInTheLoopMiddleware` + `InMemorySaver` for the gate. |
| D4 | **Hard code-level approval gate** (interrupt before `run_runbook`) | The business requirement calls propose-before-act CRITICAL; the Ballerina agent enforced it in the prompt only. LangGraph makes it structural. |
| D5 | **Topology/correlation/runbooks in-process on the orchestrator** | Keeps `run_runbook` in the same trust domain as the approval gate and correlation in one reasoning context. The MCP Proxy dissolves. |
| D6 | **MCP: FastMCP mocks + named `DataDogMCPClient`/`SplunkMCPClient`** over `langchain-mcp-adapters` (streamable-http) | Spec-compliant servers make the standard clients (and the live-vendor swap) work; the named clients honor the mandated component names and carry the auth-header hook. |
| D7 | **Low-context via agent decomposition, not `discover_tools`** | Each specialist owns only its small tool set; the orchestrator's context never holds the vendor manifests. Structural, not lazy-loading. |
| D8 | **Mesh: FastAPI + uvicorn**, one shared `mesh_common` kit | Pydantic maps 1:1 to Ballerina records; first-class OTel auto-instrumentation; async-native (chaos latency must be `asyncio.sleep`). The copy-per-service kit was a Ballerina packaging artifact. |
| D9 | **LLM: `LLM_PROVIDER` env** (`anthropic` default, `ollama`/`openai`/`amp`) | Identical env contract to the Ballerina agent; provider-swappable with no code change; default model `claude-sonnet-4-6` for apples-to-apples comparison. |
| D10 | **Side-by-side: own compose project + 1-prefixed host ports** | Lets both stacks run at once for a live comparison; container ports unchanged. |
| D11 | **Telemetry: OTLP-push metrics + OTLP logs** (drop Prometheus scrape + filelog) | The scrape/servicename-transform were Ballerina-runtime artifacts; filelog is broken on macOS Docker. The Python SDK sets `service.name` correctly. |
| D12 | **Lazy infra clients** (asyncpg/redis/nats) | Fixes the Ballerina boot-fatal gotcha where module-level clients forced infra-up for tests; pytest runs infra-free. |
| D13 | **Full 7-service parity incl. notification + NATS** | Keeps the async trace-join demo beat and identical topology/catalog to the reference. |
| D14 | **POST-create endpoints return 201** (payment/charge, invoice, inventory/reserve) | Parity with the Ballerina POST-resource default; consistent across the mesh. |
