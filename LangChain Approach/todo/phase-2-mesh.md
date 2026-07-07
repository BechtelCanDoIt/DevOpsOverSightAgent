# Phase 2 — Python Service Mesh + Load Generator

**Goal:** 7 FastAPI services + load-gen, behaviorally faithful to the Ballerina
mesh, emitting traces/logs/metrics and exposing the chaos API.

## Tasks

- [x] 2.1 `mesh_common` shared kit: `chaos.py` (async `apply_chaos`, `/chaos/*`
      listener, `X-Chaos-Token`), `obs.py` (JSON log shape, `span_ctx`, `env_or`),
      `telemetry.py` (OTLP push), `runner.py` (dual :9090/:9099 listeners),
      `db.py` (lazy asyncpg/redis/nats), `w3c.py` (traceparent build/parse).
- [x] 2.2 store, customer, order, inventory, invoice, payment, notification —
      each ports its `.bal` behavior exactly: endpoints, status mappings, seeds,
      IDs, and log message texts (the Splunk contract).
- [x] 2.3 order-service checkout saga with the full error matrix
      (400/409/502/500/503) and the NATS `orders.created` traceparent envelope.
- [x] 2.4 notification-service async subscriber: parse the traceparent, log
      "notification sent" with the parsed trace_id (the Splunk async-join).
- [x] 2.5 load-gen: baseline/spike/regression YAML patterns (copied verbatim),
      pacing + spike-window logic, per-domain flows.
- [x] 2.6 Unit tests per service (respx-mocked downstreams, fake infra).
- [x] 2.7 Parameterized Dockerfile (`code/Dockerfile`, ARG PACKAGE/MODULE).

## Exit criteria

- [x] `uv run pytest generate` green; every module imports as `__main__`.
- [x] (On a Docker host) all 7 `/health` UP; an order confirms end-to-end and
      the notification log carries the order's trace_id.
