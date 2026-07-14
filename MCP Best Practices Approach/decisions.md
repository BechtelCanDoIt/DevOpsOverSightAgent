# Locked Decisions

All architecture and tooling choices that Phases 1–7 depend on. Treat these as immutable for the demo. Re-opening any decision requires updating this file, `CLAUDE.md`, `architecture/architecture.md`, and the relevant phase spec.

---

## D1 — Splunk: Cloud trial, not Enterprise container

**Decision:** Splunk Cloud 14-day trial. No `splunk/splunk:latest` container in the compose stack.

**Rationale:** The official Splunk MCP server (Splunkbase app 7931) is built for Splunk Cloud. Running Enterprise in Docker would require a separate HEC config, different API paths, and certificate management — none of which is tested by the MCP app. The Cloud trial also demonstrates a more realistic customer architecture (SaaS Splunk, not self-hosted).

**Impact:** The OTel Collector uses the `splunk_hec` exporter pointed at `$SPLUNK_HEC_ENDPOINT`. Splunk credentials are never in the compose stack — they live in `.env` and are only required for the Phase 1 smoke test.

---

## D2 — Kubernetes runtime: kind

**Decision:** [kind](https://kind.sigs.k8s.io/) for the local Kubernetes cluster.

**Rationale:** Lightweight, fully scriptable (`kind create cluster`), no Docker Desktop license dependency (works with Rancher Desktop), and the WSO2 Agent Manager quick-start documentation targets kind. k3d is an acceptable alternative but adds complexity (k3s internals differ from upstream K8s). Docker Desktop Kubernetes is excluded — Rancher Desktop is the approved container runtime.

**Install:** `brew install kind` — not yet installed on the demo machine (see `PREREQUISITES.md`).

---

## D3 — Single OTel Collector as the telemetry shipper

**Decision:** One `otel/opentelemetry-collector-contrib` container receives all OTLP from the Ballerina services and fans out to both Splunk (HEC) and Datadog (OTLP/API).

**Rationale:** Dual native agents (a Splunk Universal Forwarder + a Datadog Agent) would require each Ballerina service to be configured twice and would create two independent trace pipelines with no shared context. A single Collector keeps the fan-out in one config file, supports the same `trace_id` in both backends (enabling cross-system correlation in the demo), and is the standard OTel pattern.

**The Datadog Agent** (`--profile saas`) is still in the compose stack as an optional add-on for Datadog APM container metadata enrichment — but it is *not* the primary telemetry path.

---

## D4 — MCP Proxy hostname and port convention

**Decision:**

| Context | Value |
|---------|-------|
| Docker Compose service name | `mcp-proxy` |
| Listener port (internal + host-mapped) | `8290` |
| URL from the K8s agent pod (k3d) | `http://host.k3d.internal:8290` |
| URL from within the compose network | `http://mcp-proxy:8290` |
| OTel service name | `mcp-proxy` |
| Agent env var | `BALLERINA_TOPOLOGY_MCP_URL` |

**Rationale:** Port `8290` was chosen to avoid conflicts with the mesh services (`8080–8087`) and the agent (`8000`/`8092`). `host.k3d.internal` is the hostname k3d registers in every pod to resolve back to the Docker host — the agent pod in k3d reaches the proxy in compose this way.

**Source:** `code/mcp/mcp-proxy/` (Ballerina package `mcp_proxy`).

---

## D5 — Mesh shape: 7 services + load-gen

**Decision:** Hybrid mesh — four spec services (`order`, `payment`, `inventory`, `notification`) plus three business domains (`customer`, `invoice`, `store`) = 7 services + `load-gen`.

**Rationale:** The four spec services give us the realistic async/sync failure modes the demo needs. Adding `customer`, `invoice`, and `store` creates a believable retail story that non-technical audiences can follow: a customer places an order → inventory is reserved → invoice is generated → notification is sent. The full graph also gives the agent more correlation surface.

---

## D6 — Repo layout

**Decision:** `DevOpsOverSightAgent/` is the GitHub push root. Ballerina source under `code/` (`agent/`, `mcp/`, `generate/` for mesh services), phase specs under `todo/`, compose stack under `compose/`.

---

## D7 — Agent framework and LLM

**Decision:** **Ballerina** agent calling **Anthropic Claude** directly via HTTP (overrides Phase 0 Python + Claude Agent SDK selection). Entire stack — mesh services, MCP servers, mock MCPs, and agent — is Ballerina. OTel instrumentation is native via `ballerinax/jaeger` + `ballerinax/prometheus`.

**Rationale:** Keeping the stack in a single language removes the Python runtime, the `amp-python-instrumentation-provider` init container, and the Agent SDK dependency. Ballerina's built-in HTTP client makes the Anthropic tool-use loop straightforward; the mock-MCP architecture means WSO2 Agent Manager is not required for local development or the demo. WSO2 Agent Manager remains an optional future integration (see Phase 0.3).

---

## D8 — Official vendor MCP servers where they exist; custom wrappers where they don't

**Decision:** Use the official *vendor* MCP servers (Splunk, Datadog) directly. For products with no native MCP at the Customer's version, build a custom Ballerina MCP wrapper over the product's own REST/management API (Phase 6). Everything is reached through the one custom MCP Proxy.

| MCP | Provider | Endpoint | Auth |
|-----|----------|----------|------|
| Splunk MCP | Splunk (Splunkbase app 7931) | hosted on Splunk Cloud instance | MCP bearer token |
| Datadog MCP | Datadog (Bits AI) | `mcp.datadoghq.com` (remote-hosted) | OAuth or API+App key |
| apim-mcp / mi-mcp / is-mcp | custom Ballerina (Phase 6) | `:8402` / `:8403` / `:8404` | `MODE=mock` default; live via product creds |
| k8s-mcp | off-the-shelf `containers/kubernetes-mcp-server` (Phase 6, `--profile infra-mcp`) | `:8405`, read-only | kubeconfig mount |
| MCP Proxy | custom (Phase 3) | `http://host.k3d.internal:8290` (from k3d pod) / `http://mcp-proxy:8290` (from compose) | `PROXY_API_KEY` (optional; empty = creds-free demo) |

**Rationale:** Both observability vendors ship and maintain their own MCP surfaces — wrapping their REST APIs would be redundant. But the Customer's WSO2 products (APIM 4.2 / MI 4.2 / IS 6.1) predate native MCP support (APIM gains it at 4.6+), so a thin Ballerina wrapper over each product's existing REST/management API is the bridge until they upgrade — mock-first so the demo runs creds-free, `MODE=live` when a real instance is available. Docker MCP was evaluated and **deferred** (its one opaque `docker` tool doesn't fit the guardrail's name-pattern filter). The Ballerina MCP Proxy is custom because no vendor owns the mesh topology, cross-system correlation, or remediation runbooks. See D9 for how these federate.

---

## D9 — MCP federation is N-backend and data-driven

**Decision:** The proxy declares every backend as a `BackendDef` row (`federation.bal`): label, env key, default URL, `required` flag, and `allowTools`/`denyTools` glob filters. Splunk and Datadog are the only `required: true` backends; all others default to an empty URL (disabled) and federate themselves the moment a URL is configured — with **zero proxy code changes** per backend.

**Rationale:** The original design hardcoded exactly two backends. Adding WSO2 products + Kubernetes made that untenable. A data-driven registry means a new backend is a table row, not new routing code; lazy `discover_tools` keeps the agent's context small regardless of how many backends are federated. Reads federate through `discover_tools`/`routeToolCall` for every backend; a tool failing its backend's `allow`/`deny` filter is never registered, so it is neither discoverable nor callable.

---

## D10 — Human approval for runbooks is code-enforced, not prompt-only

**Decision:** `topology__run_runbook` is gated in code. The agent's `makeDispatcher` intercepts every `run_runbook` attempt from the LLM loop (`code/agent/approval.bal`) and **never forwards it to the proxy** — the model gets back a halt sentinel with a single-use approval token. The only path to the proxy's real `run_runbook` is a separate `approve <token>` / `deny <token>` chat message, parsed before the LLM sees it.

**Rationale:** A prompt-only "propose before act" rule was empirically bypassed — a local model (qwen2.5:14b) autonomously executed `disable-chaos`/`restart-service` in response to an unrelated question during testing. The code gate makes bypass structurally impossible: no matter what the model emits or how it retries, it cannot reach execution. This mirrors the LangChain sibling's `HumanInTheLoopMiddleware` interrupt (Ballerina has no graph/checkpointer runtime, so it is hand-built). Scope: this protects the agent's own LLM-driven path; direct callers of the proxy (e.g. MCP Inspector) are a separate threat model covered by `PROXY_API_KEY`.
