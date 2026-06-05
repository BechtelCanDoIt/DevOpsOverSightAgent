# Phase 4 — Agent in WSO2 Agent Manager

**Goal:** deploy a Python agent under WSO2 Agent Manager, wire it to three MCP servers (Splunk, Datadog, Ballerina), and use Agent Manager's observability to watch the agent *while it watches the workload*.

## Why Python (not Ballerina) for the agent

Phase 0 research confirms WSO2 Agent Manager's auto-instrumentation is **Python-first** — `amp-instrumentation` is a Python OTel auto-instrumentation package, and `amp-python-instrumentation-provider` is the K8s init container that injects it. Building the agent in Python means we get full agent-level traces and metrics in `amp-trace-observer` with **zero code changes**. The Ballerina story stays where it shines: the workload mesh and the MCP server.

## Agent framework

**Locked: Claude Agent SDK (Python), with Anthropic Claude as the LLM.** It has a native MCP client and the cleanest tool-use loop, and it is first-class under Agent Manager's Python auto-instrumentation. (LangGraph and the OpenAI Agents SDK were the alternatives; because the Claude Agent SDK is Anthropic-native, the LLM decision is **Anthropic Claude** — this supersedes the earlier Ollama selection.)

## Tasks

### 4.1 Agent project scaffold
- [ ] `agent/` directory at repo root (exists). Substructure already scaffolded:
  - `agent/` — agent code, `pyproject.toml`, `Dockerfile`
  - `agent/datadog/mcp/` — connection config for the **remote-hosted** Datadog MCP server (`mcp.datadoghq.com`)
  - `agent/splunk/mcp/` — connection config for the **official Splunk MCP server** (Splunkbase app running on your Splunk Cloud)
  - `agent/mcp/` — client-side wiring for the custom Ballerina MCP (the server itself lives in `generate/mcp-server/`)
- [ ] `agent/pyproject.toml` with `claude-agent-sdk` (native MCP client — no langchain adapters needed)
- [ ] `agent/Dockerfile` — base image, Python 3.11, install deps, set entrypoint
- [ ] **Don't** install OTel manually — `amp-python-instrumentation-provider` injects it at pod startup

### 4.2 MCP wiring
The agent connects to three MCP servers — **two are vendor-hosted, one is ours**:
- **Splunk MCP** — the official *MCP Server for Splunk platform* (Splunkbase app 7931, "Splunk Supported"), installed on the Splunk Cloud deployment. Streamable HTTP at the app-generated HTTPS endpoint; auth via an MCP bearer token minted in the app (RBAC capability `mcp_tool_execute`). Key tool: `splunk_run_query` (runs SPL — e.g. `index=* trace_id="<id>"`); also `splunk_get_indexes`, `splunk_get_knowledge_objects`.
- **Datadog MCP** — the official *Datadog MCP Server* (Bits AI), **remote-hosted** at `https://mcp.datadoghq.com/api/unstable/mcp-server/mcp` (regional per `DD_SITE`; pin the URL — it is under `/api/unstable/` and in Preview). Streamable HTTP; auth via OAuth 2.0 (or `DD_API_KEY` + `DD_APPLICATION_KEY` headers). Toolsets selected via `?toolsets=apm,...`. Key tools: `get_datadog_metric` / `search_datadog_metrics`, `search_datadog_error_tracking_issues`, `get_datadog_trace` (full trace by ID) / `apm_search_spans`, `search_datadog_logs`, `search_datadog_monitors`.
- **Ballerina MCP** (Phase 3) — our own, in Docker Compose on `:8290`; the only **host-local** MCP — the agent pod reaches it via `host.docker.internal:8290` (or a NodePort / `extraHosts` on kind). The vendor MCPs are reached over the internet.

Connection model depends on Phase 0 finding:
- **If API Manager MCP Gateway** is in front: the agent points at *one* gateway URL with three tool namespaces. Auth via the gateway.
- **If direct**: three separate MCP client connections, each with its own URL + token/OAuth.

Recommend the gateway model — it's the WSO2-native story and cleaner for the demo narrative.

### 4.3 System prompt + agent behavior
- [ ] Write the system prompt: "You are a DevOps incident response assistant. Use the Splunk MCP for logs, Datadog MCP for metrics/traces, and the Ballerina topology MCP for service catalog and remediation. When investigating an incident: (1) check the alert, (2) pull recent metrics, (3) correlate to logs by trace_id, (4) consult topology for blast radius, (5) propose a runbook before running it, (6) summarize findings."
- [ ] Add a "propose-before-act" guardrail: the agent must call `list_runbooks` + present its choice before calling `run_runbook`
- [ ] Configure max turns and budget caps

### 4.4 Trigger mechanism
How does the agent get invoked when there's an incident? Two demo-friendly options:
- **Webhook**: Datadog monitor → HTTP webhook → agent endpoint. Most realistic.
- **CLI**: human runs `agent investigate --alert-id X`. Simpler for stage demo.

Recommend building both. Use the webhook in the rehearsed live demo so it feels real; keep the CLI as a fallback if Datadog has latency on the day.

### 4.5 Deploy to Agent Manager
Per Agent Manager docs, "internal agent" deployments use OpenChoreo under the hood:
- [ ] Create a Project in `amp-console`
- [ ] Create an Internal Agent definition pointing at the agent image
- [ ] Configure secrets: LLM API key, MCP gateway URL + token
- [ ] Configure the instrumentation version (matches what `amp-instrumentation` package supports)
- [ ] Deploy and verify the pod comes up with the init container injection visible (`amp-python-instrumentation-provider`)

### 4.6 Verify the agent's own observability
This is the meta-win — the agent monitoring the workload is itself being monitored:
- [ ] Trigger an investigation
- [ ] Open `amp-console` → traces — confirm the full agent trace shows up with tool calls as spans
- [ ] Confirm token usage, latency per LLM call, and tool call durations are visible

## Pitfalls

- **MCP server reachability from inside the cluster**: the agent runs in K8s, the MCP servers run in Docker Compose on the host. The agent pod needs to reach `host.docker.internal` (Docker Desktop) or the host's IP (kind). Set up a NodePort or `extraHosts` in the Helm values.
- **Token leakage in traces**: `amp-instrumentation` may capture request bodies. Scrub bearer tokens before they hit the trace observer — Agent Manager likely has a redaction config; use it.
- **Evaluation jobs**: Agent Manager's `evaluation-job` component exists for offline eval. Out of scope for the live demo but worth flagging as the natural next step.

## Deliverables

- A deployed agent visible in `amp-console`
- A successful end-to-end trace in `amp-trace-observer` showing tool calls to all three MCP servers
- `agent/README.md` with deploy instructions and the system prompt committed

## Exit criteria

A webhook fires (or a CLI invocation runs) → the agent investigates → its full reasoning + tool calls are visible in Agent Manager's trace observer → the agent reaches a correct diagnosis on a chaos-induced incident.
