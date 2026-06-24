# Locked Decisions

All architecture and tooling choices that Phases 1–5 depend on. Treat these as immutable for the demo. Re-opening any decision requires updating this file, `CLAUDE.md`, `architecture.md`, and the relevant phase spec.

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

## D4 — Ballerina MCP server hostname and port convention

**Decision:**

| Context | Value |
|---------|-------|
| Docker Compose service name | `ballerina-mcp` |
| Ballerina listener port (internal) | `9090` |
| Host-mapped port | `9099` |
| URL from the K8s agent (kind) | `http://host.docker.internal:9099` |
| OTel service name | `ballerina-mcp-service` |

**Rationale:** All seven Ballerina services bind on `9090` internally and are mapped to `9091–9097` on the host. Port `9099` continues that sequence (skipping 9098, which the WSO2 Agent Manager k3d quick-start cluster maps for its own use — discovered during Phase 0.3 install).

**Impact on Phase 3:** The Ballerina MCP package must start its listener on port `9090`. Add `ballerina-mcp` to the compose file following the same build/env pattern as the other services.

**Impact on Phase 4:** The agent config at `agent/mcp/` must set `BALLERINA_MCP_URL=http://host.docker.internal:9099`. The kind cluster must be started with `--config kind-config.yaml` that maps the host network (or the ExtraPortMappings block — to be confirmed in Phase 4 after the 0.4 research resolves the MCP transport question).

---

## D5 — Mesh shape: 7 services + load-gen

**Decision:** Hybrid mesh — four spec services (`order`, `payment`, `inventory`, `notification`) plus three business domains (`customer`, `invoice`, `store`) = 7 services + `load-gen`.

**Rationale:** The four spec services give us the realistic async/sync failure modes the demo needs. Adding `customer`, `invoice`, and `store` creates a believable retail story that non-technical audiences can follow: a customer places an order → inventory is reserved → invoice is generated → notification is sent. The full graph also gives the agent more correlation surface.

---

## D6 — Repo layout

**Decision:** `DevOpsOverSightAgent/` is the GitHub push root. Ballerina source under `generate/` (one package per service, including the agent), phase specs under `todo/`, compose stack under `compose/`.

---

## D7 — Agent framework and LLM

**Decision:** **Ballerina** agent calling **Anthropic Claude** directly via HTTP (overrides Phase 0 Python + Claude Agent SDK selection). Entire stack — mesh services, MCP servers, mock MCPs, and agent — is Ballerina. OTel instrumentation is native via `ballerinax/jaeger` + `ballerinax/prometheus`.

**Rationale:** Keeping the stack in a single language removes the Python runtime, the `amp-python-instrumentation-provider` init container, and the Agent SDK dependency. Ballerina's built-in HTTP client makes the Anthropic tool-use loop straightforward; the mock-MCP architecture means WSO2 Agent Manager is not required for local development or the demo. WSO2 Agent Manager remains an optional future integration (see Phase 0.3).

---

## D8 — Official MCP servers (no custom REST wrappers)

**Decision:** Use the two official MCP servers directly; build only the custom Ballerina MCP.

| MCP | Provider | Endpoint | Auth |
|-----|----------|----------|------|
| Splunk MCP | Splunk (Splunkbase app 7931) | hosted on Splunk Cloud instance | MCP bearer token |
| Datadog MCP | Datadog (Bits AI) | `mcp.datadoghq.com` (remote-hosted) | OAuth or API+App key |
| Ballerina MCP | custom (Phase 3) | `http://host.docker.internal:9098` | none (demo; add token in Phase 5) |

**Rationale:** Both vendors ship and maintain their own MCP surfaces. Writing custom REST wrappers around Splunk/Datadog APIs would be redundant, fragile, and unmaintainable. The Ballerina MCP is custom because no vendor owns the mesh topology, the cross-system correlation logic, or the remediation runbooks.
