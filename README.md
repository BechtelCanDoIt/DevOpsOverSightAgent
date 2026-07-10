# DevOps OverSight Agent

An AI agent that diagnoses production incidents by correlating signals across
**Splunk** (logs) and **Datadog** (metrics/traces) over **MCP**, in a realistic
Ballerina/Python microservice mesh — then proposes a specific remediation and
waits for a human to approve it before anything changes in production.

This repo contains **two independent reference implementations** of that same
capability, built to compare architectural approaches head-to-head against the
same mesh and the same chaos scenario.

See [`business requirements/business-requirements.md`](business%20requirements/business-requirements.md)
for the full business case, stakeholder requirements, and success metrics.

## The two options

| | [Ballarina/MCP Best Practices Approach`](MCP%20Best%20Practices%20Approach/) | [`LangChain Approach`](LangChain%20Approach/) |
|---|---|---|
| **Stack** | Ballerina, end to end | Python 3.12 + LangChain / LangGraph |
| **Shape** | One agent behind a single **MCP Proxy** that federates Splunk & Datadog | An orchestrator that delegates to two specialist agents (Datadog, Splunk) over the **A2A protocol** |
| **Docs** | [`README.md`](MCP%20Best%20Practices%20Approach/README.md) · [`architecture/architecture.md`](MCP%20Best%20Practices%20Approach/architecture/architecture.md) | [`README.md`](LangChain%20Approach/README.md) · [`architecture/architecture.md`](LangChain%20Approach/architecture/architecture.md) |

Both stand up the same 7-service retail mesh, run the same 5-minute
inject-chaos-and-recover demo, and enforce the same hard rule: the agent may
**propose** a fix, but a runbook only executes after explicit human approval.

## Architecture

Each approach owns its own deep-dive architecture doc — topology, telemetry
fan-out, the correlation/remediation flow, design decisions, and known
gotchas:

- **Ballerina + MCP Proxy** → [`MCP Best Practices Approach/architecture/architecture.md`](MCP%20Best%20Practices%20Approach/architecture/architecture.md)
- **LangChain + A2A** → [`LangChain Approach/architecture/architecture.md`](LangChain%20Approach/architecture/architecture.md)

For a guided comparison of the two — including measured (not guessed)
reliability and speed results on both a local and a cloud AI model — see the
presentation decks in [`presentation/`](presentation/README.md).

## Results
![Testing Results Image](Result%20Presentation/TestingResults.png)