# generate/ — Ballerina service mesh (Phase 2)

The 7-service retail mesh + `load-gen`. One Ballerina package per directory;
`generate/<x>/` → service name `<x>-service`. Cross-cutting conventions (the
seeded observability/logging/chaos kit, connector versions, the compose contract,
and the NATS trace-propagation envelope) live in **[`CONVENTIONS.md`](CONVENTIONS.md)** —
read it first.

## Packages

| Dir | Service | Routes (`:9090`) | Backing infra | Notes |
|---|---|---|---|---|
| `store/` | store-service | `GET /products`, `GET /products/{id}` | Postgres `storedb` | calls inventory for live stock |
| `customer/` | customer-service | `POST /customers`, `GET /customers/{id}` | Postgres `customerdb` | seeds customers 1..5; 404 on missing (order validates here) |
| `order/` | order-service | `POST /orders` | Postgres `orderdb`, NATS | orchestrator: customer→inventory→payment→invoice, then publishes `orders.created` |
| `inventory/` | inventory-service | `GET /stock/{sku}`, `POST /reserve` | Redis + Postgres `inventorydb` | Redis-first, Postgres on miss (cold-cache story); seeds SKU-001..005 |
| `invoice/` | invoice-service | `POST /invoices`, `GET /invoices/{id}`, `POST /invoices/{id}/pay` | Postgres `invoicedb` | |
| `payment/` | payment-service | `POST /charge` | none (in-process mock-bank) | **headline chaos target** |
| `notification/` | notification-service | `GET /health` only | NATS subscriber | consumes `orders.created`, re-emits `trace_id` for the Splunk async join |
| `load-gen/` | load-gen | — (driver) | — | drives the 5 front-doors; `--pattern baseline\|spike\|regression` |

Every service also exposes `GET /health` (`:9090`), token-gated `POST /chaos/{latency,error,reset}`
(`:9099`, internal only), and Prometheus metrics (`:9797`). The Ballerina **package** is named
`<x>_service`; the OTel Collector rewrites `_service`→`-service` so the load-bearing name shows up
downstream.

## Build a single package

```bash
cd generate/<svc> && /Library/Ballerina/bin/bal build      # -> target/bin/<svc>_service.jar
```
(Connectors — postgresql/redis/nats/jaeger/prometheus — are resolved from Ballerina Central.)

## Run the whole mesh (recommended)

The services depend on Postgres/Redis/NATS + the OTel Collector, so the simplest path is the
compose stack — it builds all images and wires everything:

```bash
docker compose -f compose/docker-compose.yml up -d --build
```
See [`compose/README.md`](../compose/README.md) for ports, profiles, and the SaaS wiring.

## Run one service locally (dev loop)

Bring up just the infra, then `bal run` the service with env pointing at localhost:

```bash
docker compose -f compose/docker-compose.yml up -d postgres redis nats otel-collector

cd generate/customer
DB_HOST=localhost OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 \
  /Library/Ballerina/bin/bal run

# then:
curl localhost:9090/health
curl -X POST localhost:9090/customers -H 'content-type: application/json' -d '{"name":"Ada","email":"ada@x.io"}'
```

`load-gen` picks its pattern from `LOADGEN_PATTERN` (or `--pattern`), defaulting to `baseline`:
```bash
cd generate/load-gen && LOADGEN_PATTERN=spike /Library/Ballerina/bin/bal run
```

> Note: trace/span IDs are generated locally even when the Collector is unreachable, so JSON logs
> still carry `trace_id`/`span_id`; only the OTLP *export* is best-effort.

## Verification status

- ✅ All 8 packages `bal build` clean against Ballerina 2201.13.3.
- ✅ Runtime-validated: `/health`, JSON logs with populated `trace_id`/`span_id`, chaos
  latency/error injection + token gating, load-gen YAML parsing + worker loop.
- ⏳ Live Datadog APM service map + Splunk `trace_id` join, and the chaos-incident anomaly
  checks (todo/phase-2-ballerina.md §2.7) require the Splunk/Datadog trial creds, which
  Phase 0 defers until test time. The stack runs creds-free today (Collector → `debug`).
