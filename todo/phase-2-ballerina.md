# Phase 2 — Ballerina service mesh + traffic generator

**Goal:** build a realistic retail microservice mesh in Ballerina that emits traces, logs, and metrics via OTel so the observability stack from Phase 1 has something interesting to show. All source lives under `generate/`.

## Why a mesh, not a single service

The whole demo turns on **correlation across services**. One service can demonstrate metrics and logs but not topology, blast-radius, or "which downstream caused this." A multi-service mesh + an async hop is the minimum interesting shape — and the wider the realistic graph, the better the blast-radius story.

## Layout & naming

- All Ballerina source lives in `generate/` at the repo root — **one package per directory**, no `ballerina/` intermediate.
- Directory `generate/<x>/` maps to service name `<x>-service` via `OTEL_SERVICE_NAME` (e.g. `generate/payment/` → `payment-service`). The `-service` suffix is load-bearing: Phases 3 & 5 reference `payment-service`, `inventory-service`, and `notification-service` by name.

## Services — hybrid mesh (7 services + load-gen)

The mesh keeps the four original spec services (`order, payment, inventory, notification`) **and** adds three business domains (`customer, invoice, store`). The traffic generator drives the five front-facing domains; `payment` and `notification` are exercised transitively.

| Service | Dir | Role | Talks to | Infra | Failure modes (for chaos) | Traffic-gen target |
|---|---|---|---|---|---|---|
| `store-service` | `generate/store/` | Storefront / catalog browse | `inventory`, Postgres | Postgres | latency, 500 | ✅ |
| `customer-service` | `generate/customer/` | Customer profiles / accounts | Postgres | Postgres | latency, 500 | ✅ |
| `order-service` | `generate/order/` | Front-door HTTP API: `POST /orders` | `customer`, `inventory`, `payment`, `invoice`; NATS → `notification` | Postgres | DB slow query, 500 on validation | ✅ |
| `inventory-service` | `generate/inventory/` | Reserves stock | Redis, then Postgres on miss | Redis + Postgres | cold-cache latency spike | ✅ |
| `invoice-service` | `generate/invoice/` | Generates invoice / billing record | Postgres | Postgres | latency, 500 | ✅ |
| `payment-service` | `generate/payment/` | Charges card (mocked) | in-process **mock-bank** (dummy response — no real external call) | — | timeout, sporadic 502 (**headline demo**) | indirect |
| `notification-service` | `generate/notification/` | Sends order confirmation | NATS subscriber | NATS | slow consumer / backlog | indirect |
| `load-gen` | `generate/load-gen/` | Drives traffic; holds chaos one-liners | all front-door services | — | n/a — it's the driver | — |

### Topology (Phase 3 `get_dependencies` must match this exactly)

```
load-gen ─► store, customer, order, invoice, inventory
order ─┬─► customer  (validate)
       ├─► inventory (reserve) ─► redis ─► postgres (on miss)
       ├─► payment  (charge)   ─► mock-bank (in-process mock)
       ├─► invoice  (bill)
       └─NATS─► notification   (confirm)   [async — explicit trace-context in envelope]
store ─► inventory
{order, customer, invoice, store} ─► postgres
```

## Tasks

### 2.1 Ballerina project layout
- [X] All packages live under `generate/` (exists). All **eight** dirs present: `order`, `payment`, `inventory`, `customer`, `invoice`, `store`, `notification`, `load-gen`
- [X] One Ballerina package per service dir, each with `Ballerina.toml`, `Dockerfile`, and `*.bal` source
- [X] Org slug renamed project-wide from old name → `devopspoc` (all `Ballerina.toml` + `Dependencies.toml`)
- [X] Shared `Ballerina.toml` conventions: `observabilityIncluded = true`; OTel exporter endpoint via `Config.toml` / env (`OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317`)
- [X] Each service has its own `Dockerfile` (two-stage build, base image's Java 21 runtime)
- [X] Each service wired into `compose/docker-compose.yml` with build context `../generate/<svc>`

### 2.2 OTel instrumentation
Ballerina's observability module emits OTel-format data natively. Per service:
- [X] Enable observability in `Ballerina.toml` (`[build-options] observabilityIncluded = true`)
- [X] Set `OTEL_SERVICE_NAME=<x>-service` per service so traces are labeled correctly
- [X] Side-effect imports `ballerinax/jaeger` + `ballerinax/prometheus` in `tracing.bal` (per CONVENTIONS.md these two imports + the `Config.toml` settings are the full instrumentation wiring — no additional code is required)
- [X] `obs.bal` provides `spanCtx()` + `logInfo()`/`logError()` so JSON logs carry `trace_id`/`span_id` — joins Datadog traces to Splunk logs
- [X] Add custom attributes for correlation: `service.namespace=devops-poc`, `deployment.environment=demo`, `git.commit` build-arg — via `OTEL_RESOURCE_ATTRIBUTES` in the `x-otel-env` compose anchor; propagates to all 8 services automatically
- [ ] Confirm Ballerina SQL connector traces Postgres calls as child spans (verified once Phase 1 Splunk/Datadog smoke test is live)

### 2.3 Health endpoint
- [X] Every service exposes `GET /health` on `:9090` returning `{status, service}` — pattern is part of the seeded kit (see `generate/CONVENTIONS.md` §"Listener & route conventions"). Phase 3's MCP `get_service_health(name)` probes this.

### 2.4 Chaos toggles
Implemented in the seeded `chaos.bal` (auth-token gated via `X-Chaos-Token`, internal-network-only `:9099` listener). Business handlers call `applyChaos()` at the top of each request.
- [X] `POST /chaos/latency` body `{ "ms": 2000, "duration_s": 60 }` → injects latency for the window
- [X] `POST /chaos/error` body `{ "rate": 0.3, "status": 502 }` → returns the status for that fraction of requests
- [X] `POST /chaos/reset` → back to normal
- [x] Operator-facing reachability of `/chaos/*` from host scripts — host ports 9191–9197 published in compose (e.g. `curl http://localhost:9196/chaos/enable` hits payment-service)

These are the levers the Phase 5 demo script pulls to create the incident the agent will diagnose. The headline scenario targets `payment-service`.

### 2.5 Traffic generator
`generate/load-gen/` is a small Ballerina worker, not a service. It drives the **five business domains** (`customer, order, invoice, inventory, store`):
- [X] Reads a YAML pattern file: baseline RPS, ramp shape, spike windows (patterns live in `generate/load-gen/patterns/`)
- [X] Per-domain flow definitions — `customer` (signup/lookup), `order` (`POST /orders` with varied SKUs + customer IDs), `invoice` (query/pay), `inventory` (stock check), `store` (catalog browse)
- [X] Realistic order payloads so the `order → customer/inventory/payment/invoice` fan-out and the `order → notification` NATS hop both light up
- [X] Logs its own OTel spans so the load itself is visible in Datadog
- [X] Supports `--pattern baseline` / `--pattern spike` / `--pattern regression` CLI args (via `selectPattern`)
- [X] Runs as a long-lived container in the compose stack, defaulting to `baseline`

### 2.6 Data layer
- [X] `order, customer, invoice, store, inventory` each back onto Postgres. `compose/postgres/init.sql` provisions the five databases (`orderdb`, `customerdb`, `invoicedb`, `storedb`, `inventorydb`); **table DDL lives with each service** as `CREATE TABLE IF NOT EXISTS` in its `init()` function so the schema travels with the code (see `init.sql` comment block + each service's main `.bal`)
- [X] `inventory` reads Redis first, falls back to Postgres on a miss (drives the cold-cache latency story)

### 2.7 Verification
- [X] All eight packages build clean offline (`bal build` per CLAUDE.md status)
- [X] Health endpoints, JSON logs with `trace_id`, chaos toggles, and NATS trace envelope are runtime-validated locally
- [ ] `docker compose -f compose/docker-compose.yml up -d` brings up the mesh + load-gen (pending Phase 1 Splunk/Datadog creds)
- [ ] `GET /health` returns 200 on all seven services in the live stack
- [ ] Datadog APM service map shows **all seven services** with edges matching the topology above
- [ ] Splunk shows logs from all seven services, with the `trace_id` field populated
- [ ] Flip a chaos toggle on `payment-service` → confirm the resulting latency/errors show up in Datadog within 30s
- [ ] Confirm logs for the failing requests in Splunk carry the same `trace_id` Datadog shows
- [ ] Async check: an `order` that fans out to `notification` over NATS shows as a single connected trace

### 2.8 Unit tests (NEW)

Each package has a `tests/` directory with `@test:Config` functions in the same package, exercising **pure** helpers only (no live Postgres/Redis/NATS/HTTP). The shared seeded-kit helpers (`envOr`, `chaosAuthed`, `chaosErrorResponse`) are covered in every service; service-specific pure logic is covered where the source had testable surface or where a minimal refactor exposed one.

| Service | Test file | Tests | Service refactor for testability |
|---|---|---|---|
| `order` | `generate/order/tests/order_service_test.bal` | 9 | extracted `buildTraceparent(traceId, spanId)` from inline NATS envelope construction |
| `payment` | `generate/payment/tests/payment_service_test.bal` | 9 | none (target functions were already pure) |
| `inventory` | `generate/inventory/tests/inventory_service_test.bal` | 8 | extracted `canReserve(current, qty)` from inline guard |
| `notification` | `generate/notification/tests/notification_service_test.bal` | 12 | extracted `parseTraceparent(tp)` + `isLowerHex` from inline NATS envelope parsing |
| `customer` | `generate/customer/tests/customer_service_test.bal` | 9 | added `buildCustomer`, `validateNewCustomer`, `isValidCustomerId` |
| `store` | `generate/store/tests/store_service_test.bal` | 9 | extracted `buildProductDetail`, `skuValid` |
| `invoice` | `generate/invoice/tests/invoice_service_test.bal` | 10 | added `validateNewInvoice`, `rowToInvoice`, `newIssuedInvoice` |
| `load-gen` | `generate/load-gen/tests/load_gen_test.bal` | 14 | extracted `pickDomainAt(weights, randDecimal)` for deterministic testability |

**Total: 80 `@test:Config` functions across 8 packages.**

- [x] Tests written
- [x] `bal test` per package — 80/80 passing across all 8 packages (2201.13.3). Required making infra clients non-crashing when offline: changed `final X = check new(...)` → `final X|error = new(...)` and wrapped `init()` in `do{} on fail{}`. Module-level variables require local copies before type-narrowing (Ballerina doesn't narrow module-level vars); `@nats:ServiceConfig` can't annotate a var, so notification uses `Listener.attach(svc, subject)` instead.

## Pitfalls

- **Ballerina OTel exporter version drift**: the Swan Lake observability module's OTel version may lag the Collector's. If you see "unknown field" warnings in the Collector logs, pin to a compatible OTel SDK version.
- **Trace context propagation across NATS**: HTTP→HTTP propagation is automatic; HTTP→NATS→HTTP needs explicit headers in the NATS message envelope (`order` → `notification`). Build that in from day one — async correlation is half the demo.
- **Postgres queries showing as untraced**: enable the Ballerina SQL connector's tracing flag, otherwise DB latency won't show as a child span.
- **Multi-service Postgres**: four services now share Postgres — give each its own schema/DB so a chaos-induced slow query in one doesn't muddy the others.

## Deliverables

- **Eight Ballerina packages** (seven services + `load-gen`), each container-ready — ✅
- A YAML pattern library: `baseline.yaml`, `spike.yaml`, `regression.yaml`, plus per-domain flow definitions — ✅
- `generate/README.md` with `bal run` instructions per service for local dev outside compose — ✅
- A `tests/` directory per package with `@test:Config` unit tests (80 functions total) — ✅
- A working Datadog service map screenshot in the repo (proof of life) showing all seven services — ⏳ pending Phase 1 live creds

## Exit criteria

The mesh runs for 10 minutes under `baseline` load with no errors in Datadog, then chaos toggles produce the expected anomalies in **both** Datadog and Splunk, joined by `trace_id`. The Datadog service map shows the full seven-service topology with the `order → notification` async edge intact.
