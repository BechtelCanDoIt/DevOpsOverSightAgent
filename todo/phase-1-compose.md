# Phase 1 — Docker Compose observability stack

**Goal:** stand up the observability backends and supporting infrastructure that the Ballerina mesh (Phase 2) and the agent (Phase 4) will use. Nothing in this phase generates traffic yet — that's Phase 2.

## What goes in the compose stack

| Service | Purpose | Notes |
|---|---|---|
| **otel-collector** | Single point that receives OTLP from Ballerina services and fans out to Splunk + Datadog | Use `otel/opentelemetry-collector-contrib` — has both Splunk HEC and Datadog exporters built in |
| **datadog-agent** | Ships metrics + APM traces to Datadog SaaS | Configured via env: `DD_API_KEY`, `DD_SITE`, `DD_APM_ENABLED=true` |
| **nats** *(or kafka)* | Async event bus for the notification service | NATS is lighter — recommend NATS unless Kafka is needed for the customer story |
| **jaeger** *(dev only)* | Local trace inspection during build | Optional; remove for the customer demo |
| **postgres** | Shared backing store for `order`, `customer`, `invoice`, and `store` services (gives us a real DB to generate query latency on) | One Postgres, **a schema/DB per service** via an init script — DB queries show up as spans |
| **redis** | Cache for `inventory-service` (cache misses → backend latency) | Same — gives the agent something interesting to correlate |

> Note: Splunk is *not* in the compose stack — telemetry ships to **Splunk Cloud trial** via the OTel Collector's `splunk_hec` exporter. This was a locked decision in Phase 0. If Phase 0 chose Splunk Enterprise container instead, add a `splunk` service here using `splunk/splunk:latest`.

## Tasks

### 1.1 Repo layout
- [ ] Create `compose/` directory at the repo root (`DevOpsAgent/compose/`)
- [ ] `compose/docker-compose.yml` — main stack. Phase 2 adds the seven Ballerina services + `load-gen` (+ the Phase 3 `mcp-server`) here; their build contexts point at `../generate/<svc>`
- [ ] `compose/.env` (gitignored) and `compose/.env.example` (committed) — Splunk HEC token, Datadog keys, etc.
- [ ] `compose/otel-collector/config.yaml` — OTLP receiver, Splunk HEC + Datadog exporters, batch processor
- [ ] `compose/postgres/init.sql` — create a schema/DB per backing service (`order`, `customer`, `invoice`, `store`) so a chaos-induced slow query in one doesn't muddy the others
- [ ] `compose/README.md` — `docker compose up -d`, expected ports, where logs go

### 1.2 OTel Collector configuration
The Collector is the most architecturally important piece. Its config should:
- Receive OTLP on gRPC (4317) and HTTP (4318) from Ballerina services
- Pipe **traces** → both `datadog` exporter and `splunk_hec` exporter (so the agent can correlate)
- Pipe **logs** → `splunk_hec` exporter (Splunk is the log-of-record)
- Pipe **metrics** → `datadog` exporter (Datadog is the metrics-of-record)
- Add resource attributes: `deployment.environment=demo`, `service.namespace=devops-poc`
- Include a `batch` processor and `memory_limiter` so it survives load tests

### 1.3 Datadog Agent
- [ ] Mount the Docker socket so the agent auto-discovers containers
- [ ] Set `DD_APM_ENABLED=true` and `DD_APM_NON_LOCAL_TRAFFIC=true` so Ballerina services on the compose network can push traces
- [ ] Set `DD_LOGS_ENABLED=false` — logs go via OTel→Splunk only, avoid double-billing

### 1.4 Networking
- [ ] One user-defined bridge network `devops-poc`
- [ ] Expose only what humans need on the host: OTel Collector OTLP ports (so we can curl test from outside), Jaeger UI 16686, Postgres 5432 for poking around
- [ ] Internal-only: NATS, Redis, Datadog Agent

### 1.5 Smoke test
Before declaring Phase 1 done:
- [ ] `docker compose up -d` — all containers healthy
- [ ] From host, send a test OTLP trace with `otel-cli` or `curl` to the Collector
- [ ] Confirm the trace appears in **both** Datadog APM **and** Splunk (search `index=*` or wherever HEC drops it)
- [ ] Confirm a test log line via OTLP shows up in Splunk
- [ ] Confirm Datadog Agent's metrics (e.g. `docker.cpu.usage`) appear in Datadog

## Pitfalls to flag now

- **Splunk HEC token scope**: the trial's default HEC token may not have permission to create new indexes. Send to `main` unless you set up an index in advance.
- **Datadog trace ID format**: Datadog historically used 64-bit trace IDs, OTel uses 128-bit. The Datadog exporter handles this but you'll see two trace IDs in the UI — `dd.trace_id` (64-bit) and `otel.trace_id` (128-bit). The agent's correlation logic needs to know which to use when joining Datadog ↔ Splunk.
- **Clock skew**: containers vs. SaaS endpoints — keep an eye on ingest delays during the smoke test.

## Deliverables

- A `docker compose up -d` that produces a working pipeline from a test OTLP send to both Splunk + Datadog
- `compose/README.md` with troubleshooting for the three pitfalls above

## Exit criteria

Phase 1 is done when a manually-emitted OTLP trace shows up in both Datadog APM and Splunk searches within 60 seconds, and the same for a manually-emitted log line (Splunk only).
