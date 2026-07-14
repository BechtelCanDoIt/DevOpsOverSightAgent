# compose/ — workload + observability stack

> Phase 1 owns the full Splunk/Datadog wiring. The files here were created during
> **Phase 2** so the mesh can actually run and be verified. A default `up` brings up the
> 7-service Ballerina mesh + `load-gen` + supporting infra + the OTel Collector,
> **plus the MCP layer (mcp-proxy + the splunk/datadog/apim/mi/is mock MCP servers) and
> the DevOps agent** (Phases 3/4/6), and runs **with no SaaS credentials** (the Collector
> exports to `debug`; the agent defaults to local Ollama).

## Quick start

```bash
cp .env.example .env                      # defaults are fine for a creds-free run
docker compose -f compose/docker-compose.yml up -d --build
docker compose -f compose/docker-compose.yml ps

# Watch telemetry flow through the Collector (traces/metrics/logs to debug):
docker compose -f compose/docker-compose.yml logs -f otel-collector

# Health-check every mesh service from the host (see port map below):
for p in 9091 9092 9093 9094 9095 9096 9097; do curl -s localhost:$p/health; echo; done

# Health-check the MCP layer + agent (all expose /health):
for p in 8290 8400 8401 8402 8403 8404 8092; do curl -s localhost:$p/health; echo; done

docker compose -f compose/docker-compose.yml down            # stop
docker compose -f compose/docker-compose.yml down -v         # stop + wipe Postgres
```

Stamp the git SHA into traces (`git.commit`):
```bash
GIT_COMMIT=$(git rev-parse --short HEAD) docker compose -f compose/docker-compose.yml build
```

## What runs

| Container | Image | Host port | Notes |
|---|---|---|---|
| otel-collector | `otel/opentelemetry-collector-contrib:0.119.0` | 4317/4318 | OTLP in; fans out (debug by default) |
| postgres | `postgres:16-alpine` | 5432 | DB-per-service via `postgres/init.sql` |
| redis | `redis:7-alpine` | 6379 | `inventory` cache |
| nats | `nats:2.10-alpine` | 4222, 8222 | `order → notification` bus (+ monitoring :8222) |
| store / customer / order / inventory / invoice / payment / notification | built from `../code/generate/<svc>` | 9091–9097 | `:9090` business+`/health`, `:9099` chaos (internal), `:9797` metrics |
| load-gen | built from `../code/generate/load-gen` | — | drives traffic (`LOADGEN_PATTERN=baseline`) |
| mcp-proxy | `devops-poc/mcp-proxy` | 8290 | federating MCP proxy — topology/correlation/runbook/skill tools + routes to the backends below |
| splunk-mock-mcp / datadog-mock-mcp | `devops-poc/{splunk,datadog}-mock-mcp` | 8400 / 8401 | required backends (mock by default; live via env) |
| apim-mcp / mi-mcp / is-mcp | `devops-poc/{apim,mi,is}-mcp` | 8402 / 8403 / 8404 | WSO2-product MCP wrappers; `MODE=mock` default, `MODE=live` flips to the real product |
| devops-oversight-agent | `devops-poc/devops-oversight-agent` | 8092 (→ :8000) | the agent — `/investigate`, `/chat`, `/health-report`, `/top5` |

Optional profiles: `--profile dev` (Jaeger UI :16686), `--profile saas` (Datadog Agent — needs `DD_API_KEY`), `--profile infra-mcp` (Kubernetes MCP `k8s-mcp` on :8405, read-only — run `make infra-up` first to prepare a container-reachable kubeconfig), `--profile wso2` (real WSO2 MI/APIM/IS containers for live-mode MCP — optional, heavy, amd64-only; see `todo/phase-6-mcp-expansion.md` §6.6).

Host→container port map: store 9091, customer 9092, order 9093, inventory 9094, invoice 9095, payment 9096, notification 9097 — all map to container `:9090`. The chaos listener (`:9099`) is intentionally **not** host-mapped (internal network only).

## Going to SaaS (Phase 1)

1. Fill `DD_*` and `SPLUNK_HEC_*` in `.env`.
2. In `otel-collector/config.yaml`, uncomment the `datadog` / `splunk_hec` exporters and add them to the matching pipelines (and add `filelog` to the logs pipeline + mount `/var/lib/docker/containers`).
3. `--profile saas` to start the Datadog Agent.

## Pitfalls (see architecture/architecture.md §10)

- **Trace-ID width**: Datadog shows 64-bit `dd.trace_id` + 128-bit `otel.trace_id`; Splunk holds the 128-bit form. Correlation must use the right width.
- **Splunk HEC index scope**: trial token may only write `main` — keep `SPLUNK_INDEX=main` unless an index is pre-created.
- **Rancher Desktop log paths**: the `filelog` receiver path may differ from `/var/lib/docker/containers` — adjust in Phase 1.
- **Clock skew / ingest lag**: containers vs SaaS — watch during the smoke test.
