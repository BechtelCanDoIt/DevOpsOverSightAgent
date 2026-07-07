# Manual Demo Walkthrough — LangChain / A2A stack

A slower, click-by-click companion to `script.md`. Every command runs from the
`LangChain Approach/` directory. Ports are 1-prefixed (side-by-side with the
Ballerina stack).

## 1. Start the stack

```bash
make demo-up        # docker compose up -d --build
make ps             # watch services become healthy
```

Wait until `devops-oversight-agent` is healthy (it retries A2A card resolution
against the two specialists on startup).

## 2. Baseline health

```bash
curl -s http://localhost:18092/health; echo                       # orchestrator UP
curl -s http://localhost:18400/health; echo                       # splunk-mock-mcp UP
curl -s http://localhost:18401/health; echo                       # datadog-mock-mcp UP
curl -s http://localhost:18101/.well-known/agent-card.json | head -c 200; echo   # DataDogAgent card
curl -s http://localhost:18102/.well-known/agent-card.json | head -c 200; echo   # SplunkAgent card
```

## 3. Baseline chat (no incident)

```bash
curl -s -X POST http://localhost:18092/chat -H 'Content-Type: application/json' \
  -d '{"message":"Are there any active incidents in the mesh right now?"}' | python3 -m json.tool
```

The orchestrator can delegate to the specialists and report "no active alerts"
(the mock data only shows the payment incident once chaos correlates to it).

## 4. Baseline order (mesh works)

```bash
curl -s -X POST http://localhost:19093/orders -H 'Content-Type: application/json' \
  -d '{"customerId":1,"items":[{"sku":"SKU-001","qty":2}]}' | python3 -m json.tool
# expect {"orderId":"ORD-...","status":"confirmed","total":39.98}
```

## 5. Inject chaos on payment-service

```bash
./demo/inject-chaos.sh payment-service 0.8 2000 300
# probe:
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:19096/charge \
  -H 'Content-Type: application/json' -d '{"amount":19.99,"currency":"USD","orderId":"probe"}'
# expect 502 (chaos-injected)
```

Orders now fail at the payment step with a 502:
```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:19093/orders \
  -H 'Content-Type: application/json' -d '{"customerId":1,"items":[{"sku":"SKU-001","qty":1}]}'
# expect 502 (payment failed) — sometimes 200 if the probability roll passes
```

## 6. P1 investigation

```bash
make investigate    # or the raw curl in script.md
```

Read the `summary`: root cause (chaos on payment-service, no recent deploy),
the evidence the specialists returned, and the **proposed** `disable-chaos`
runbook. Note the `sessionId`.

## 7. Approve the runbook (the hard gate)

```bash
curl -s -X POST http://localhost:18092/chat -H 'Content-Type: application/json' \
  -d '{"message":"approve","sessionId":"<sessionId from step 6>"}' | python3 -m json.tool
```

Only now does `disable-chaos` run (POST `/chaos/reset` on payment-service).
Try `{"message":"reject",...}` on a fresh investigation to see the gate hold.

## 8. Verify recovery

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:19096/charge \
  -H 'Content-Type: application/json' -d '{"amount":19.99,"currency":"USD","orderId":"recovered"}'
# expect 201
```

## 9. Reset paths

- Agent-driven: the approved `disable-chaos` runbook already reset payment.
- Manual, all services: `make reset-chaos` (or `./demo/reset.sh`).
- Direct: `curl -X POST http://localhost:19196/chaos/reset -H 'X-Chaos-Token: dev-chaos-token'`.

## 10. Inspect telemetry & shut down

```bash
make logs           # tail otel-collector (debug exporter shows spans/logs/metrics)
make demo-down
```

Other scenarios to try: latency-only chaos on inventory-service
(`./demo/inject-chaos.sh inventory-service 0.0 1500 120`), or a slow-query
regression via `LOADGEN_PATTERN=regression` before `make demo-up`.
