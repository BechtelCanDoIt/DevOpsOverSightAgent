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

### 0.2 Accounts & credentials
- [X] Splunk: decide between **Splunk Cloud trial** (recommended) and **Splunk Enterprise Docker image**. If Cloud, create the trial and capture the HEC endpoint + token. 
  - Picking cloud (14 day free trial)
  - Will get account when ready to test
- [X] Datadog: create a trial account, capture the API key + APP key, note the site (e.g. `datadoghq.com`, `us5.datadoghq.com`)
  - Only has cloud (14 day free trial)
  - Will get account when ready to test
- [X] Anthropic API key for the agent's LLM — the agent uses the **Claude Agent SDK** with **Anthropic Claude** models (supersedes the earlier Ollama selection; the SDK is Anthropic-native)
  - Will get account when ready to test

### 0.3 WSO2 Agent Manager — install & smoke test (Optional / Future)

> **Note:** The agent was re-implemented in Ballerina (see `decisions.md` D7), so Agent Manager is no longer required to run the demo. These steps are preserved for future integration if deploying to a managed agent platform.

The Agent Manager runs via the `ghcr.io/wso2/amp-quick-start:v0.15.0` dev container (not a standalone Helm chart — the chart is bundled inside the container). It creates its own k3d cluster named `amp-local`. See `PREREQUISITES.md` for the exact command; Rancher Desktop works without Colima.

- [X] Install via quick-start container (all 13 steps completed successfully; `amp-local` k3d cluster running)
- [ ] Verify `amp-console`, `amp-api`, `amp-trace-observer` pods are running — **manual step**: check `http://localhost:3000`
- [ ] Log into `amp-console` and create a stub project — **manual step**: `http://localhost:3000`, admin/admin
- [ ] Install `amctl` CLI and verify it can talk to the local control plane
- [ ] Deploy the sample agent from `wso2/agent-manager/samples` end-to-end as a sanity check

### 0.4 Understand the agent runtime contract
This is research, not config. Pull the answers from `wso2/agent-manager/documentation` and the `samples/` directory so Phase 4 isn't a guessing game.

- [X] How does Agent Manager expect MCP servers to be referenced from an agent?
  - **Env-var / secrets injection model.** No platform-native MCP registry CRD. You define a Project in `amp-console`, declare the MCP URLs and tokens as **secrets** → they become environment variables in the agent pod. The agent's Python code constructs `MCPServerHTTP` objects using those env vars (e.g. `os.environ["MCP_SPLUNK_URL"]`). Verify: check `wso2/agent-manager/samples/` for whether a post-2025 release added a first-class "MCP Connections" resource type.

- [X] What transports does the platform support?
  - **stdio ruled out** (not viable across K8s pod boundaries). **HTTP/SSE confirmed** safe fallback. **Streamable HTTP preferred** but API Manager MCP Gateway support unverified — check WSO2 API Manager 4.4+ release notes. The two vendor MCPs (Datadog `mcp.datadoghq.com`, Splunk app 7931) both use Streamable HTTP, so the agent SDK must support it regardless; the open question is whether the *gateway proxy* handles it without buffering SSE.

- [X] Where do MCP server endpoints get injected?
  - **Environment variables** set via `amp-console` secrets. No sidecar proxy, no ConfigMap injection. Agent Manager's add-on value is the `amp-python-instrumentation-provider` init container (OTel auto-instrumentation), not a connection broker. The `agent/splunk/mcp/`, `agent/datadog/mcp/`, `agent/mcp/` directories hold per-MCP config blocks; sensitive fields come from env.

- [X] Does WSO2 API Manager's MCP Gateway sit in front of MCP servers?
  - **Optional / not confirmed for this POC.** The preferred architecture is one gateway URL with three tool namespaces (auth, rate-limiting, audit "for free"), but the gateway's ability to proxy external HTTPS MCP endpoints (Splunk Cloud, `mcp.datadoghq.com`) and handle Streamable HTTP is unverified. **Phase 4 plan:** wire direct env-var connections first; layer the gateway after direct connectivity is proven. Biggest unknown: does API Manager MCP Gateway support Streamable HTTP without buffering SSE?

### 0.5 Lock decisions
Resolve the open questions from the planning README and write them into `decisions.md`:

- [X] Splunk Cloud trial **or** Splunk Enterprise container → **Splunk Cloud trial** (see `decisions.md` D1)
- [X] kind **or** k3d **or** Docker Desktop K8s → **kind** (see `decisions.md` D2)
- [X] OTel Collector as single shipper **or** dual native agents → **single OTel Collector** (see `decisions.md` D3)
- [X] MCP server hostname/port convention → **`ballerina-mcp:9090` internal, `:9098` host-mapped, `http://host.docker.internal:9098` from K8s** (see `decisions.md` D4)
- [X] **Mesh shape:** hybrid — keep all four spec services (`order`, `payment`, `inventory`, `notification`) **and** add three business domains (`customer`, `invoice`, `store`) = 7 services + `load-gen`. Traffic generator drives the five front-facing domains (`customer`, `order`, `invoice`, `inventory`, `store`)
- [X] **Repo/source layout:** `DevOpsOverSightAgent/` is the GitHub push root; Ballerina source under `code/` (`agent/`, `mcp/`, `generate/` for mesh services), specs under `todo/`
- [X] **Agent framework & LLM:** Ballerina agent calling **Anthropic Claude** directly via HTTP — entire stack is Ballerina (overrides Phase 0 Python + Claude Agent SDK selection; see `decisions.md` D7)
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
