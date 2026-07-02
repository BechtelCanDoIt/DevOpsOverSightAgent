# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **DevOps Observability POC**: an AI agent (under WSO2 Agent Manager) correlates signals across **Splunk** and **Datadog** over **MCP** to diagnose and remediate incidents in a Ballerina microservice mesh. `DevOpsOverSightAgent/` is the repository root for the GitHub push.

**Read these first — they are the canonical docs. Do not duplicate their content here; update them and link.**

- [`README.md`](README.md) — component catalog: every service, the three MCP servers, and the agent client, plus getting-started.
- [`architecture.md`](architecture/architecture.md) — deep dive: topology diagram, telemetry fan-out, cross-system correlation, the remediation flow, design decisions, and known gotchas.
- [`todo/README.md`](todo/README.md) → [`todo/phase-0..5`](todo/) — the **authoritative**, phase-by-phase implementation specs and exit criteria.

## Source layout

- `code/` — all Ballerina source, split into three sub-directories: `agent/` (DevOps OverSight agent), `mcp/` (MCP Proxy + splunk-mock-mcp + datadog-mock-mcp), and `generate/` (7 mesh services + load-gen).
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
- **Mesh:** hybrid 7-service retail mesh + `load-gen` (see [`README.md`](README.md))
- **Mock MCPs:** `splunk-mock-mcp` (port 8400) and `datadog-mock-mcp` (port 8401) stand in for live vendor MCPs until creds arrive; swapped via env vars with no code changes
- **Agent maxTurns:** 30 (bumped from 20 to absorb discover_tools overhead from lazy loading; do NOT reduce below 25 — Ollama non-determinism plus discovery turns mean some runs need up to 25 turns)

## Commands (as implemented per phase)

```bash
# Phase 1 — Docker Compose stack (creds-free default; mocks + debug exporter)
docker compose -f compose/docker-compose.yml up -d
docker compose -f compose/docker-compose.yml ps

# Phase 2/3/4 — Ballerina services (run individually during dev)
cd code/generate/<service-name> && bal run
cd code/generate/<service-name> && bal test  # mesh; use code/agent or code/mcp/<svc> for agent/MCP

# Run all 12 packages
./tests/runUnitTests.sh

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
| 3 | MCP Proxy (`mcp-proxy`) | Mostly complete — 9-tool proxy built & tested (22 tests), 4 runbooks, audit log, OTel instrumented, compose wired. Remaining: bearer-token auth, live Splunk/DD proxy routing, live inspector verification |
| 4 | Ballerina agent (+ mock MCPs) | Mostly complete — Ballerina agent with Anthropic tool-use loop built & tested (8 tests); splunk-mock-mcp (8 tests) + datadog-mock-mcp (11 tests) built; all compose-wired. Remaining: end-to-end investigation test, Datadog webhook config, Agent Manager deploy (optional) |
| 5 | Demo rehearsal & verification | Not started |

Detailed exit criteria for each phase are in `todo/phase-<N>-*.md`.
