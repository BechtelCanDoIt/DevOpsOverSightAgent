# Phase 0 — Prerequisites & approved-software check

**Goal:** verify every tool the demo depends on is installed at a known version, document any approval gates, and lock in the open decisions before any compose files or Ballerina code get written.

## Tasks

### 0.1 Approved-software gate
- [X] Confirm Docker (Rancher) is on the approved-software list for the demo machine
- [X] Confirm Docker Compose v2 (`docker compose version` returns >= 2.20)
- [X] Confirm Ballerina Swan Lake (`bal version` — pin to current Update channel, e.g. 2201.x)
- [X] Confirm local Kubernetes runtime: pick one of **kind**, **k3d**, or **Docker Desktop Kubernetes**. Recommendation: **kind** (lightweight, scriptable, no Docker Desktop license concerns)
- [X] Confirm Helm v3 (`helm version`)
- [X] Confirm `kubectl` is available and points at the local cluster
- [X] Confirm Python 3.11+ (for the agent itself — Agent Manager's instrumentation is Python-native)

### 0.2 Accounts & credentials
- [X] Splunk: decide between **Splunk Cloud trial** (recommended) and **Splunk Enterprise Docker image**. If Cloud, create the trial and capture the HEC endpoint + token. 
  - Picking cloud (14 day free trial)
  - Will get account when ready to test
- [X] Datadog: create a trial account, capture the API key + APP key, note the site (e.g. `datadoghq.com`, `us5.datadoghq.com`)
  - Only has cloud (14 day free trial)
  - Will get account when ready to test
- [X] Anthropic API key for the agent's LLM — the agent uses the **Claude Agent SDK** with **Anthropic Claude** models (supersedes the earlier Ollama selection; the SDK is Anthropic-native)
  - Will get account when ready to test

### 0.3 WSO2 Agent Manager — install & smoke test
The Agent Manager runs on Kubernetes. Per the repo's quick start, deploy with the `wso2-agent-manager` Helm chart.

- [X] Install the Helm chart from `wso2/agent-manager` per the [Quick Start](https://wso2.github.io/agent-manager/docs/getting-started/quick-start/)
- [ ] Verify `amp-console`, `amp-api`, `amp-trace-observer` pods are running
- [ ] Log into `amp-console` and create a stub project
- [ ] Install `amctl` CLI and verify it can talk to the local control plane
- [ ] Deploy the sample agent from `wso2/agent-manager/samples` end-to-end as a sanity check — proves the platform works before we layer our own agent on top

### 0.4 Understand the agent runtime contract
This is research, not config. Pull the answers from `wso2/agent-manager/documentation` and the `samples/` directory so Phase 4 isn't a guessing game.

- [ ] How does Agent Manager expect MCP servers to be referenced from an agent? (URL config? secret-managed credentials? OpenChoreo-managed proxy?)
- [ ] What transports does the platform support — stdio (unlikely in K8s), HTTP/SSE, streamable HTTP?
- [ ] Where do MCP server endpoints get injected — environment variables, ConfigMap, or a platform-managed registry?
- [ ] Does WSO2 API Manager's **MCP Gateway** sit in front of MCP servers in this architecture? If yes, our Ballerina MCP server gets registered there.

### 0.5 Lock decisions
Resolve the open questions from the planning README and write them into `decisions.md`:

- [ ] Splunk Cloud trial **or** Splunk Enterprise container
- [ ] kind **or** k3d **or** Docker Desktop K8s
- [ ] OTel Collector as single shipper **or** dual native agents (Datadog Agent + Splunk forwarder)
- [ ] MCP server hostname/port convention so Phases 2, 3, 4 agree
- [X] **Mesh shape:** hybrid — keep all four spec services (`order`, `payment`, `inventory`, `notification`) **and** add three business domains (`customer`, `invoice`, `store`) = 7 services + `load-gen`. Traffic generator drives the five front-facing domains (`customer`, `order`, `invoice`, `inventory`, `store`)
- [X] **Repo/source layout:** `DevOpsAgent/` is the GitHub push root; Ballerina source under `generate/` (one package per service), Python agent under `agent/`, specs under `todo/`
- [X] **Agent framework & LLM:** Claude Agent SDK (Python) with **Anthropic Claude** as the LLM — supersedes the earlier Ollama pick (the Claude Agent SDK is Anthropic-native)
- [X] **Official MCP servers confirmed:** Datadog MCP (Bits AI, remote-hosted `mcp.datadoghq.com`, OAuth or API+App key) and Splunk MCP (Splunkbase app 7931 on Splunk Cloud, MCP bearer token) — the agent connects to both; no custom REST wrappers needed

## Deliverables

- `PREREQUISITES.md` — versions, commands, install notes
- `decisions.md` — one paragraph per locked decision with rationale
- A green kind cluster with `amp-console` reachable and the sample agent running
- A `.env.example` capturing every secret variable Phases 1–4 will need

## Exit criteria

Phase 0 is done when:
1. Every tool above prints a version, and a runbook to install the same on a fresh machine exists
2. WSO2 Agent Manager's sample agent runs locally end-to-end
3. The five locked decisions are written down — Phase 1 doesn't start until they are
