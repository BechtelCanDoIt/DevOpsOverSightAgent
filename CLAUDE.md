# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **DevOps Observability POC**: an AI agent (under WSO2 Agent Manager) correlates signals across **Splunk** and **Datadog** over **MCP** to diagnose and remediate incidents in a Ballerina microservice mesh. `DevOpsAgent/` is the repository root for the GitHub push.

**Read these first — they are the canonical docs. Do not duplicate their content here; update them and link.**

- [`README.md`](README.md) — component catalog: every service, the three MCP servers, and the agent client, plus getting-started.
- [`architecture.md`](architecture.md) — deep dive: topology diagram, telemetry fan-out, cross-system correlation, the remediation flow, design decisions, and known gotchas.
- [`todo/README.md`](todo/README.md) → [`todo/phase-0..5`](todo/) — the **authoritative**, phase-by-phase implementation specs and exit criteria.

## Source layout

- `generate/` — all Ballerina source, one package per directory (`generate/<x>/` → service `<x>-service`); plus `load-gen/` (traffic generator) and `mcp-server/` (custom Ballerina MCP).
- `agent/` — Python agent + per-MCP connection config (`splunk/mcp/`, `datadog/mcp/`, `mcp/`).
- `compose/` — Docker Compose stack (Phase 1) · `catalog/` — MCP service catalog (Phase 3) · `demo/` — demo scripts (Phase 5) · `todo/` — phase specs.

## Locked Decisions (Phase 0)

- **LLM:** Anthropic Claude (the Claude Agent SDK is Anthropic-native)
- **Agent framework:** Claude Agent SDK, **Python** (required for WSO2 Agent Manager auto-instrumentation)
- **Kubernetes:** kind cluster
- **Splunk:** Cloud trial (not Enterprise container); telemetry ships via the OTel Collector's `splunk_hec` exporter
- **Telemetry:** single OTel Collector fanning out to Splunk (HEC) + Datadog
- **Mesh:** hybrid 7-service retail mesh + `load-gen` (see [`README.md`](README.md))

## Commands (as implemented per phase)

```bash
# Phase 1 — Docker Compose stack
docker compose -f compose/docker-compose.yml up -d
docker compose -f compose/docker-compose.yml ps

# Phase 2 — Ballerina services (run individually during dev)
cd generate/<service-name> && bal run

# Phase 4 — Kind cluster + Agent Manager
kind create cluster --name devops-agent
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
| 0 | Prerequisites & decisions | Mostly complete — tools verified, decisions locked |
| 1 | Docker Compose observability stack | Scaffolded — compose stack + OTel Collector + Postgres init built (in Phase 2 to make the mesh runnable); collector exports to `debug` by default. Real Splunk/Datadog exporters + smoke test pending trial creds |
| 2 | Ballerina service mesh + traffic generator | Mostly complete — 8 packages (7 services + load-gen) build clean & runtime-validated (health, JSON logs w/ `trace_id`, chaos toggles, NATS trace envelope). Live Datadog/Splunk verification (§2.7) deferred to test time (creds) |
| 3 | Ballerina MCP server | Not started |
| 4 | Python agent in WSO2 Agent Manager | Not started |
| 5 | Demo rehearsal & verification | Not started |

Detailed exit criteria for each phase are in `todo/phase-<N>-*.md`.
