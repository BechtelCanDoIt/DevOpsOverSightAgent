# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **DevOps Observability POC**: an AI agent (under WSO2 Agent Manager) correlates signals across **Splunk** and **Datadog** over **MCP** to diagnose and remediate incidents in a Ballerina microservice mesh. `DevOpsOverSightAgent/` is the repository root for the GitHub push; Parent folder.

**Read these first — they are the canonical docs. Do not duplicate their content here; update them and link.**

- [`README.md`](README.md) — component catalog: every service, the MCP Proxy and its federated backends (splunk/datadog mocks + apim/mi/is WSO2-product wrappers + optional k8s), the agent client, and getting-started.
- [`architecture.md`](architecture/architecture.md) — deep dive: topology diagram, telemetry fan-out, cross-system correlation, the remediation flow, design decisions, and known gotchas.
- [`todo/README.md`](todo/README.md) → [`todo/phase-0..7`](todo/) — the **authoritative**, phase-by-phase implementation specs and exit criteria.

## Source layout

- `code/` — all Ballerina source, split into three sub-directories: `agent/` (DevOps OverSight agent), `mcp/` (MCP Proxy + splunk-mock-mcp + datadog-mock-mcp + apim-mcp + mi-mcp + is-mcp), and `generate/` (7 mesh services + load-gen). Off-the-shelf `k8s-mcp` is a compose service only (no source here).
- `compose/` — Docker Compose stack (Phase 1) · `demo/` — demo scripts (Phase 5) · `todo/` — phase specs.

## Locked Decisions (Phase 0 + override)

- **LLM:** **Configurable via `LLM_PROVIDER` env var** — all four providers are in `code/agent/llm_client.bal`:
  - `anthropic` (default) — Anthropic Messages API; AMP proxy via `ANTHROPIC_URL`; requires `ANTHROPIC_API_KEY`
  - `ollama` — local Ollama `/api/chat`; creds-free; default model `qwen3.5:9b` at `OLLAMA_BASE_URL`
  - `openai` — OpenAI `/v1/chat/completions`; override endpoint with `OPENAI_BASE_URL`; requires `OPENAI_API_KEY`
  - `amp` — WSO2 AMP AI gateway (OpenAI-compatible); AMP injects `LLM_BASE_URL` + optional `LLM_API_KEY`; set `LLM_MODEL`
- **Agent framework:** **Ballerina** (overrides Phase 0 Python decision — entire stack is Ballerina; Ballerina OTel covers Agent Manager observability needs)
- **Kubernetes:** kind cluster
- **Splunk:** Cloud trial (not Enterprise container); telemetry ships via the OTel Collector's `splunk_hec` exporter
- **Telemetry:** single OTel Collector fanning out to Splunk (HEC) + Datadog
- **Agent tracing (optional):** `ballerinax/amp` can ship the agent's own OTel trace straight to the AMP Console's Traces view instead of the collector — toggle via `AMP_TRACING_PROVIDER=amp` in `compose/.env`, no code change. See [`README.md`](README.md#agent-tracing--the-amp-console-optional).
- **Mesh:** hybrid 7-service retail mesh + `load-gen` (see [`README.md`](README.md))
- **Mock MCPs:** `splunk-mock-mcp` (port 8400) and `datadog-mock-mcp` (port 8401) stand in for live vendor MCPs until creds arrive; swapped via env vars with no code changes
- **Agent maxTurns:** `configurable int agentMaxTurns` (env `AGENT_MAX_TURNS`), default **40** as of Phase 6/7's backend expansion (bumped from 30 — more federated backends means more `discover_tools` turns; do NOT reduce below 25 — Ollama non-determinism plus discovery turns mean some runs need up to 25 turns)
- **MCP federation is N-backend, not hardcoded-to-2 (Phase 6/7):** `mcp-proxy`'s `federation.bal` declares every backend as a `BackendDef` row (label, env key, default URL, required, allowTools/denyTools) — Splunk/Datadog are the only `required: true` backends; everything else (apim/mi/is/k8s/docker) defaults to disabled (`""` URL) and federates itself in the moment a URL is configured, with zero proxy code changes. Three new Ballerina-authored WSO2-product MCP servers — `apim-mcp` (:8402), `mi-mcp` (:8403), `is-mcp` (:8404) — wrap APIM 4.2/MI 4.3/IS 6.1's own REST/management APIs, **mock-first with a `MODE=live` flag** (matches the splunk/datadog mock pattern). Kubernetes MCP (`k8s-mcp`, :8405, off-the-shelf `containers/kubernetes-mcp-server`, `--profile infra-mcp`) federates read-only. Docker MCP was evaluated and **deferred** (Docker's official `mcp-gateway` exposes one opaque `docker` tool — incompatible with the guardrail's name-pattern filtering); `DOCKER_MCP_URL` stays unset by design.
- **Include toggles (Y|N):** `INCLUDE_WSO2_MCP` (default Y) and `INCLUDE_K8S_MCP` (default N) on the proxy (`federation.bal`, env-overridable, accept Y/yes/N/no/true/false) are a hard on/off gate ABOVE the per-backend URL check — `N` drops that whole backend group from the federation table entirely (never connected/discovered/routed), regardless of URL. splunk/datadog are never gated. Verified by integration Test 12.
- **Write guardrail:** reads federate through `discover_tools`/`routeToolCall` for every backend; a tool failing a backend's `allowTools`/`denyTools` glob filter is simply never registered — never discoverable, never callable by the agent. Writes (real `restart-service`/`scale-service`) run ONLY through `callBackendToolDirect` (bypasses the registry on purpose), gated behind `K8S_WRITE_ENABLED` (default `false`) — every write path falls back to the pre-existing stub unless a real backend is connected AND this is explicitly enabled.
- **Code-level human-approval gate (Phase 4 §4.9):** `topology__run_runbook` is enforced in code, not just prompted. `code/agent/approval.bal` + `makeDispatcher` intercept every `run_runbook` attempt from the LLM loop — it is **never** forwarded to the proxy; the model gets back a `RUNBOOK_HALT_MARKER` sentinel with an approval token, which hard-stops the tool-use loop across all four LLM providers. The **only** path that calls the proxy's real `run_runbook` is a separate `approve <token>` / `deny <token>` chat message, parsed in `chat()` before the LLM ever sees it (tokens are single-use). Mirrors the LangChain sibling's `HumanInTheLoopMiddleware` interrupt (Ballerina has no graph/checkpointer runtime, so it's hand-built). Live-verified: a non-compliant local model that autonomously reached for `run_runbook` was provably blocked (audit log gains an entry only after approval).
- **Real-products Compose profile (`--profile wso2`) — native arm64, verified:** All three products (`wso2mi:4.3.0`, `wso2am:4.2.0`, `wso2is:6.1.0`) are built LOCALLY from extracted distributions via `make wso2-build-images` (`compose/wso2/Dockerfile` + `scripts/build-wso2-images.sh`, source dir `WSO2_SRC_DIR`, default `~/dev/wso2`). The Dockerfile layers the pure-Java product onto a **multi-arch Temurin 11 base**, so the images run **natively on arm64 or amd64 — no QEMU emulation** and no dependence on WSO2's amd64-only registry images. Verified on Apple Silicon: all three build + boot native aarch64 (MI ~3s, IS ~25s, APIM ~51s) with health/management APIs responding, and the full **live chain proxy → mi-mcp(live) → real wso2mi** returns real data. `make wso2-up` is the one-switch live path (sets `{APIM,MI,IS}_MCP_MODE=live` + `INCLUDE_WSO2_MCP=Y`, starts the profile); `make wso2-down` reverts to mock. **MI uses 4.3.0** — the extracted 4.2.0 dir had a broken OSGi state (management API wouldn't start); 4.3.0 boots clean. Mock mode remains the default creds-free demo/CI path. **All three live clients are now verified** end-to-end through the proxy against the real products (APIM: PizzaShackAPI/DefaultApplication/Default gateway; IS: Console app + health; MI: message-processors). Live-client fixes made while verifying: **MI** login is `GET /management/login` + HTTP Basic (was POST+JSON → empty "No content"); **APIM** needed an explicit urlencoded token form-body (a `map<string>` serialized wrong) + the devportal scopes `apim:app_manage apim:subscribe` (devportal returns 401 without them) + `apim_list_subscriptions` must pass an `applicationId` (unscoped list is HTTP 400, so it aggregates per-app); **IS** worked as written.

## Commands (as implemented per phase)

```bash
# Phase 1 — Docker Compose stack (creds-free default; mocks + debug exporter)
docker compose -f compose/docker-compose.yml up -d
docker compose -f compose/docker-compose.yml ps

# Phase 2/3/4 — Ballerina services (run individually during dev)
cd code/generate/<service-name> && bal run
cd code/generate/<service-name> && bal test  # mesh; use code/agent or code/mcp/<svc> for agent/MCP

# Run all 15 packages (+ a naming regression scrub-check)
./tests/runUnitTests.sh

# Phase 6/7 — proxy federation + skills integration test (no LLM/SaaS creds needed)
./tests/runDockerConfigTests.sh
# Opt-in: also verify the Kubernetes MCP backend (needs `make infra-up` first)
./tests/runDockerConfigTests.sh --with-infra

# Phase 4 — Trigger an investigation (agent running in compose)
curl -X POST http://localhost:8092/investigate \
  -H "Content-Type: application/json" \
  -d '{"service":"payment-service","severity":"P1","description":"502 spike"}'

# Phase 4 — Inject chaos into payment-service (chaos port published as 9196)
# 502 errors at 80% rate for 5 min:
curl -X POST http://localhost:9196/chaos/error \
  -H "X-Chaos-Token: dev-chaos-token" \
  -H "Content-Type: application/json" \
  -d '{"rate": 0.8, "status": 502, "duration_s": 300}'
# Latency injection (ms + duration_s):
curl -X POST http://localhost:9196/chaos/latency \
  -H "X-Chaos-Token: dev-chaos-token" \
  -H "Content-Type: application/json" \
  -d '{"ms": 2000, "duration_s": 300}'
# Reset all chaos:
curl -X POST http://localhost:9196/chaos/reset \
  -H "X-Chaos-Token: dev-chaos-token"

# Phase 5 — SaaS demo (requires DD_API_KEY, DD_SITE, SPLUNK_HEC_TOKEN, SPLUNK_HEC_URL, SPLUNK_INDEX in compose/.env)
docker compose -f compose/docker-compose.yml -f compose/docker-compose.saas.yml --profile saas up -d

# Phase 4 — Kind cluster + Agent Manager (optional / future)
kind create cluster --name devops-oversight-agent
helm install wso2-agent-manager wso2/agent-manager -n agent-manager --create-namespace
amctl status

# Phase 5 — Demo orchestration (Makefile targets TBD)
make demo-up
make demo-down
make rehearse
```

## Phase Status

| Phase | Name | Status |
|-------|------|--------|
| 0 | Prerequisites & decisions | Nearly complete — tools verified, all decisions locked (`decisions.md`), WSO2 Agent Manager installed. Remaining: manual console login + stub project + sample agent smoke test |
| 1 | Docker Compose observability stack | Scaffolded — compose stack + OTel Collector + Postgres init built; local OTLP smoke test passing. Real Splunk/Datadog exporters + smoke test pending trial creds |
| 2 | Ballerina service mesh + traffic generator | Mostly complete — 8 packages (7 services + load-gen) build clean & runtime-validated, 80 unit tests passing. Live Datadog/Splunk verification (§2.7) deferred to test time (creds) |
| 3 | MCP Proxy (`mcp-proxy`) | N-backend federation (Refactor R4) built & tested — 81 tests, 5 runbooks, write guardrail, optional bearer auth, per-backend `/health`, audit log, OTel instrumented, compose wired |
| 4 | Ballerina agent (+ mock MCPs) | Complete — Anthropic/Ollama/OpenAI/AMP tool-use loop built & tested (37 tests); `/health-report`, `/top5`, and `Health`/`Top5` chat-command shortcuts bypass the LLM loop entirely (§4.9); **code-level `run_runbook` approval gate** (`approve <token>`/`deny <token>`) live-verified; splunk-mock-mcp (8 tests) + datadog-mock-mcp (11 tests). Remaining: end-to-end investigation test, Datadog webhook config, Agent Manager deploy (optional) |
| 5 | Demo rehearsal & verification | Partial — see `todo/phase-5-verify.md` §5.6 for the hardening checklist (`make scrub-check` now gates every unit test run) |
| 6 | MCP expansion — WSO2 products + K8s/Docker | Complete (mock path) — apim-mcp/mi-mcp/is-mcp (11/9/8 tests) + Kubernetes MCP federated read-only; Docker MCP evaluated and deferred; `--profile wso2` real-products scaffolded but not runtime-verified (host emulation gap) |
| 7 | Skills & smarter runbook selection | Complete — `suggest_runbooks` (metadata-scored), `health_report`/`top_issues`/`list_deployments` (server-side aggregation), all verified live via `runDockerConfigTests.sh` |

Detailed exit criteria for each phase are in `todo/phase-<N>-*.md`.
