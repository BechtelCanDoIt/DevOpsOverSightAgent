# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **DevOps Observability POC**: an AI agent (under WSO2 Agent Manager) correlates signals across **Splunk** and **Datadog** over **MCP** to diagnose and remediate incidents in a Ballerina microservice mesh. `DevOpsOverSightAgent/` is the repository root for the GitHub push.

**Read these first — they are the canonical docs. Do not duplicate their content here; update them and link.**

- [`README.md`](README.md) — component catalog: every service, the three MCP servers, and the agent client, plus getting-started.
- [`architecture.md`](architecture/architecture.md) — deep dive: topology diagram, telemetry fan-out, cross-system correlation, the remediation flow, design decisions, and known gotchas.
- [`todo/README.md`](todo/README.md) → [`todo/phase-0..5`](todo/) — the **authoritative**, phase-by-phase implementation specs and exit criteria.

## Source layout

- `LangChain Approach` - Typical LangChain agents using A2A protocal for accessing DataDog and Splunk MCP Servers.
- `MCP Best Practices Approach` - uses Ballerina code to create an agent that calls a MCP Proxy to reach out to DataDog and Splunk cloud MCP Servers.


