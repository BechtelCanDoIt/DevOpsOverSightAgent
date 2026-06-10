# generate/ — Ballerina mesh conventions (Phase 2)

Every service package lives in `generate/<x>/` and maps to service name `<x>-service`
(via `OTEL_SERVICE_NAME`). The Ballerina **package** is named `<x>_service` (hyphens
are illegal in package names); the OTel Collector normalizes `_service` → `-service`,
so the load-bearing `-service` name shows up in Datadog/Splunk.

These conventions were validated against **Ballerina 2201.13.3 (Swan Lake U13)** — the
exact APIs, versions, and two boot-fatal footguns below are confirmed, not guessed.

## The seeded kit — DO NOT modify or recreate these files

Each service dir already contains an identical, **validated** cross-cutting kit. Use it;
don't rewrite it:

| File | What it gives you |
|---|---|
| `Ballerina.toml` | `[package]` (correct name) + `[build-options] observabilityIncluded = true` |
| `Config.toml` | JSON logs + observability (jaeger=OTLP→collector, prometheus metrics). `samplerParam = 1.0` **must stay a decimal**. |
| `tracing.bal` | imports `ballerinax/jaeger` + `ballerinax/prometheus` (side-effect activation) |
| `obs.bal` | logging + helpers (API below) |
| `chaos.bal` | `/chaos/{latency,error,reset}` on listener `:9099`, token-gated, + `applyChaos()` |
| `Dockerfile` | two-stage build; runs the jar via the base image's Java 21 |

You only write the **service-specific** files: business logic, the data layer, and (for
`order`/`notification`) the NATS leg.

## Helper API (from the seeded `obs.bal` / `chaos.bal`)

```ballerina
envOr("DB_HOST", "postgres")          // env var with default
logInfo("reserved stock")             // structured JSON log, auto trace_id/span_id
logError("charge failed", e)          // same, with error
spanCtx()                             // returns [traceId, spanId] (32-hex, 16-hex)

// Chaos gate — call at the TOP of every business handler:
int? injected = applyChaos();         // applies injected latency; returns a status to fail with
if injected is int {
    return chaosErrorResponse(injected);   // -> http:Response with that status
}
```

For richer logs, call `log:printInfo` directly with extra fields, e.g.
`log:printInfo("order placed", trace_id = tid, span_id = sid, order_id = oid);`
(Ballerina also auto-adds `traceId`/`spanId` to every line when observability is on.)

## Listener & route conventions

- **One listener on `:9090`** hosts your business service(s) **and** `/health`:
  ```ballerina
  listener http:Listener mainListener = new (9090);
  service /health on mainListener {
      resource function get .() returns json => {status: "UP", 'service: "<x>-service"};
  }
  service /<route> on mainListener { ... }   // business routes
  ```
- `/chaos/*` is already served on `:9099` by the seeded `chaos.bal`. Don't add it.
- `:9797` is the Prometheus metrics endpoint (handled by the extension).
- Business handler shape: gate on `applyChaos()` first, then do the work, then `logInfo(...)`.

## Connector cheatsheet (versions are pre-cached — no network needed)

**Postgres** — `ballerinax/postgresql` 1.18.0 + driver `ballerinax/postgresql.driver` 1.6.3
(import the driver `as _` so the JDBC jar is bundled). Uses `ballerina/sql`; queries are
auto-traced as child spans when observability is on.
```ballerina
import ballerinax/postgresql;
import ballerinax/postgresql.driver as _;
import ballerina/sql;

final postgresql:Client db = check new (
    host = envOr("DB_HOST", "postgres"), port = check int:fromString(envOr("DB_PORT", "5432")),
    username = envOr("DB_USER", "poc"), password = envOr("DB_PASSWORD", "pocpass"),
    database = envOr("DB_NAME", "<x>db"));
// On startup: CREATE TABLE IF NOT EXISTS ... + seed. Use parameterized `sql:ParameterizedQuery` (`...${val}`).
```

**Redis** — `ballerinax/redis` 3.2.2.
```ballerina
import ballerinax/redis;
final redis:Client cache = check new (connection = {
    host: envOr("REDIS_HOST", "redis"), port: check int:fromString(envOr("REDIS_PORT", "6379"))});
```

**NATS** — `ballerinax/nats` 3.3.1. `NATS_URL` default `nats://nats:4222`. Subject **`orders.created`**.
Publisher (`order`): `nats:Client`; subscriber (`notification`): a `nats:Service` on a `nats:Listener`.

## Compose contract (what the container env provides)

Read everything via `envOr(...)` so local `bal run` works with the defaults too.

| Env var | Default | Used by |
|---|---|---|
| `DB_HOST` `DB_PORT` `DB_USER` `DB_PASSWORD` `DB_NAME` | postgres / 5432 / poc / pocpass / `<x>db` | order, customer, invoice, store, inventory |
| `REDIS_HOST` `REDIS_PORT` | redis / 6379 | inventory |
| `NATS_URL` | nats://nats:4222 | order, notification |
| `CUSTOMER_URL` `INVENTORY_URL` `PAYMENT_URL` `INVOICE_URL` | `http://<svc>:9090` | order (all four), store (`INVENTORY_URL`) |
| `OTEL_SERVICE_NAME` | `<x>-service` | all (set per-service in compose) |
| `OTEL_RESOURCE_ATTRIBUTES` | `service.namespace=devops-poc,deployment.environment=demo,git.commit=<sha>` | all (set via `x-otel-env` anchor; `git.commit` comes from `GIT_COMMIT` build-arg at compose launch) |
| `CHAOS_TOKEN` | dev-chaos-token | all (seeded chaos.bal) |

DB names: `orderdb`, `customerdb`, `invoicedb`, `storedb`, `inventorydb`. `payment` and
`notification` have **no** database.

## NATS trace-propagation envelope (order → notification) — build this in from day one

HTTP→HTTP context propagates automatically; **NATS does not**. The publisher injects W3C
trace-context into the message so the async leg joins the same trace by `trace_id` in Splunk.

Envelope published by `order` to subject `orders.created` (JSON):
```json
{ "orderId": "...", "customerId": "...", "total": 42.50,
  "traceparent": "00-<32-hex traceId>-<16-hex spanId>-01" }
```
- `order`: build `traceparent` from `spanCtx()` → `string traceparent = string `00-${tid}-${sid}-01`;` and include it in the payload.
- `notification`: parse `traceparent`, extract the 32-hex `trace_id` + 16-hex `span_id`, and
  log the confirmation with those (`log:printInfo("notification sent", trace_id = tid, span_id = sid, order_id = ...)`),
  so Splunk shows the async leg under the **same** `trace_id`. (Datadog visual trace-stitching
  across NATS is a known Ballerina limitation — document it; the Splunk join is the contract.)

## Build / verify gate (REQUIRED before you finish)

```bash
cd generate/<x> && /Library/Ballerina/bin/bal build
```
Must end with `Generating executable / target/bin/<x>_service.jar` and **no ERRORs**. Fix only
your business code — never the seeded kit. (Connectors are pre-cached; build is offline-fast.)

## Gotchas already handled / to remember

- `samplerParam` in `Config.toml` **must** be `1.0` (decimal) — `1` crashes startup. (Already correct in the kit.)
- A `lock` block may touch only **one** module-level `isolated` variable — group mutable state
  into a single `isolated record` (see `chaos.bal`). 
- Postgres `sql:ParameterizedQuery` interpolation (`` `...${x}` ``) is parameterized/safe — use it, not string concat.
- `bal run app.jar` in the container uses the bundled Java 21 (system `java` may be older).
