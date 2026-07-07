# Phase 1 — Compose Observability Stack

**Goal:** the OTel Collector + supporting infra run locally; telemetry reaches a
`debug` exporter with no SaaS creds.

## Tasks

- [x] 1.1 `compose/docker-compose.yml` (project `devops-poc-py`, own network +
      volumes, 1-prefixed host ports).
- [x] 1.2 OTel Collector config (`otel-collector/config.yaml`): OTLP-only
      receivers, debug exporter, traces/metrics/logs pipelines. No Prometheus
      scrape, no filelog (deviations documented in architecture §4).
- [x] 1.3 `otel-collector/config.saas.yaml` + `docker-compose.saas.yml` overlay:
      real Datadog + Splunk HEC exporters, gated behind creds + `--profile saas`.
- [x] 1.4 Postgres (`postgres/init.sql` — 5 databases), Redis, NATS with
      healthchecks; optional Jaeger (`--profile dev`) and Datadog Agent sidecar.
- [x] 1.5 `.env.example` documenting every knob.

## Exit criteria

- [x] `docker compose -f compose/docker-compose.yml config` validates.
- [x] SaaS overlay validates.
- [ ] `make demo-up` then `make logs` shows OTLP spans/logs/metrics in the
      collector debug output (run on a Docker host).
