# compose/ — workload + observability stack

> Phase 1 owns the full Splunk/Datadog wiring. The files here were created during
> **Phase 2** so the mesh can actually run and be verified. They bring up the
> 7-service Ballerina mesh + `load-gen` + supporting infra + the OTel Collector,
> and run **with no SaaS credentials** (the Collector exports to `debug`).

## Quick start

```bash
cp .env.example .env                      # defaults are fine for a creds-free run
docker compose -f compose/docker-compose.yml up -d --build
docker compose -f compose/docker-compose.yml ps

# Watch telemetry flow through the Collector (traces/metrics/logs to debug):
docker compose -f compose/docker-compose.yml logs -f otel-collector

# Health-check every service from the host (see port map below):
for p in 9091 9092 9093 9094 9095 9096 9097; do curl -s localhost:$p/health; echo; done

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
| otel-collector | `otel/opentelemetry-collector-contrib` | 4317/4318 | OTLP in; fans out (debug by default) |
| postgres | `postgres:16` | 5432 | DB-per-service via `postgres/init.sql` |
| redis | `redis:7` | — | `inventory` cache (internal) |
| nats | `nats:2.10` | — | `order → notification` bus (internal) |
| store / customer / order / inventory / invoice / payment / notification | built from `../generate/<svc>` | 9091–9097 | `:9090` business+`/health`, `:9099` chaos (internal), `:9797` metrics |
| load-gen | built from `../generate/load-gen` | — | drives traffic (`LOADGEN_PATTERN=baseline`) |

Optional profiles: `--profile dev` (Jaeger UI :16686), `--profile saas` (Datadog Agent — needs `DD_API_KEY`).

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
