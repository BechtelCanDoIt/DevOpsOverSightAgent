# Demo Script — DevOps Observability POC
**Total target runtime: 5 minutes**
Presenter: solo or paired (one drives terminal, one narrates).

> **Run mode.** This script is written for the **Docker Compose** path (the guaranteed,
> creds-free demo): the agent runs on `:8092` and talks to the **mock** Splunk/Datadog MCP
> servers, which return realistic canned signals. The proof is the **agent's own response** —
> its cross-signal reasoning, diagnosis, and proposed runbook. Live Datadog/Splunk dashboards
> and the WSO2 Agent Manager trace view are **optional bonuses** (see the callouts) that need
> creds / a running AMP cluster respectively; the core story does not depend on them.
>
> **Mock vs. live is a pure env-var swap** — `SPLUNK_MCP_URL` / `DATADOG_MCP_URL` point at the
> mocks today; point them at the official Splunk/Datadog MCPs (with creds) and nothing else changes.
>
> **LLM is configurable** via `LLM_PROVIDER`: `ollama` (default — local, creds-free, e.g.
> `qwen3.5:9b` reached at `host.docker.internal:11434`) or `anthropic` (set a real
> `sk-ant-api03` key + `AGENT_MODEL`). This demo runs on **local Ollama** — no API key, no cost.
> Note: a local-model investigation runs many sequential tool-call turns, so it takes ~1–2 min.

---

## Component reference (verified ports)

| Thing | URL | Notes |
|---|---|---|
| Agent | `http://localhost:8092` | `/health`, `/investigate`, `/chat`, `/webhook/alert` (listener :8000 in-container) |
| Topology MCP | `http://localhost:8290` | custom Ballerina MCP |
| Splunk mock MCP | `http://localhost:8400` | |
| Datadog mock MCP | `http://localhost:8401` | |
| payment-service | `http://localhost:9096` | business API (`/charge`, `/health`) |
| payment chaos | `http://localhost:9196` | `/chaos/latency|error|reset` (token-gated) |
| mesh chaos ports | `9191`–`9197` | store…notification, in that order |

---

## Pre-demo Checklist (5 min before showtime)

- [ ] Stack up: `docker compose -f compose/docker-compose.yml up -d` (or `make demo-mock-up` to rebuild first)
- [ ] All four POC services healthy:
  ```bash
  for p in 8092 8290 8400 8401; do echo -n "$p: "; curl -s http://localhost:$p/health; echo; done
  # expect {"status":"UP",...} from each
  ```
- [ ] LLM reachable (default Ollama): `curl -s http://localhost:11434/api/tags | jq -r '.models[].name'` — expect a tool-capable model (e.g. `qwen3.5:9b`). Agent defaults to `LLM_PROVIDER=ollama`.
- [ ] Baseline payment works:
  ```bash
  curl -s -o /dev/null -w "charge -> HTTP %{http_code}\n" -X POST http://localhost:9096/charge \
    -H "Content-Type: application/json" -d '{"amount":42.50,"currency":"USD","orderId":"warmup"}'
  # expect HTTP 201
  ```
- [ ] `export CHAOS_TOKEN=dev-chaos-token` (already the default in the scripts)
- [ ] Two terminal windows side-by-side: one to drive, one tailing `docker compose logs -f devops-oversight-agent`
- [ ] *(Bonus)* Datadog APM + Splunk Search tabs open — only if SaaS creds are set in `compose/.env`
- [ ] *(Bonus)* AMP console `http://localhost:3000` (amp-admin/amp-admin) — only if the AMP cluster is up

---

## Story Beat 1 — Inject Chaos (0:00 – 0:45)

**Narration:** "Our payment service is about to start misbehaving — 30% of requests return HTTP 502 with 2 seconds of added latency. A realistic Saturday-afternoon incident."

**Command (run live):**
```bash
make inject-chaos
# or directly:
./demo/inject-chaos.sh payment-service 0.3 2000 300
```

**Expected output:**
```
==> Injecting chaos into payment-service (host port 9196)
    Error rate: 0.3 (HTTP 502)   Latency: 2000ms for 300s
{"status":"latency injected", "ms":2000, "duration_s":300}[ok] latency injected
{"status":"error injected", "rate":0.3, "errorStatus":502}[ok] error rate injected
Chaos active on payment-service. Run: make reset-chaos  to restore normal operation.
```

**Show it's real** — fire a handful of charges and watch ~30% fail:
```bash
for i in $(seq 1 12); do curl -s -o /dev/null -w "%{http_code} " -X POST http://localhost:9096/charge \
  -H "Content-Type: application/json" -d '{"amount":10,"currency":"USD","orderId":"c'$i'"}'; done; echo
# expect a mix of 201s and 502s
```

---

## Story Beat 2 — Signals Diverge (0:45 – 1:15)

**Narration:** "Two independent observability systems each see *half* the picture. Datadog sees latency and error-rate spikes on payment-service. Splunk holds the 5xx log lines with the stack context. Neither alone has the full story — and that's the point."

**Compose/mock path (always works):** the mock MCP servers stand in for these backends and return the same shape of signal the live systems would. We'll watch the agent pull from both in Beat 3.

> **Bonus — live SaaS (only if `DD_API_KEY` / `SPLUNK_HEC_TOKEN` set in `compose/.env`):**
> - Datadog: open the `payment-service` APM page — p99 latency graph spiking.
> - Splunk: `index=<your-index> service=payment-service status>=500 | stats count by status`.

**Talking point:** "The agent's job is to correlate across these two systems by `trace_id` — exactly what an on-call engineer does by hand, alt-tabbing between tools."

---

## Story Beat 3 — Agent Investigates (1:15 – 2:45)

**Narration:** "The agent receives the P1 alert, queries all three MCP servers, and reasons across the combined signal set."

**Trigger the agent (run live):**
```bash
make investigate
# equivalently:
curl -s -X POST http://localhost:8092/investigate \
  -H "Content-Type: application/json" \
  -d '{"service":"payment-service","severity":"P1","description":"502 spike detected","id":"INC-TEST-1"}' | jq .
```

**Watch the agent's tool calls in the log window** (`docker compose logs -f devops-oversight-agent`). You'll see the namespaced MCP tools fire, e.g.:
- `topology__list_services` / `topology__get_dependencies` — pulls the dependency graph (order-service depends on payment-service)
- `datadog__get_datadog_metric` / `datadog__apm_search_spans` — error-rate + latency on payment-service
- `topology__correlate_trace` — bridges a Datadog trace to its Splunk logs
- `splunk__splunk_run_query` — fetches the correlated 5xx log lines
- `topology__find_recent_deploys` — rules out a recent deploy
- `topology__list_runbooks` — surfaces remediation options **before** proposing one

**Expected response** — the agent returns `{"status":"investigated","alert_id":...,"summary":"<markdown>"}`.
Pipe through `jq -r .summary` to render it. A representative local-Ollama run produced:

```
**Findings:**
- Monitor alert: payment-service error rate > 10% (active)
- Error metrics: payment.request.errors spiked 2 → 53 in 5 minutes
- Service health: UP (HTTP 200) — anomalies suggest chaos vs crash
- Recent deploy: Success 60 min ago (not root cause)
- Historical incident: INC-001 — "chaos injection left enabled after load test"
- Runbook available: disable-chaos (matches historical resolution)

**Analysis:** 502 spike is NOT from the recent deploy; matches the historical chaos-left-enabled pattern.

**Proposal:** Execute `disable-chaos` on payment-service.  ⚠️ Awaiting approval before execution.
```

(Exact wording varies per run — local models are non-deterministic. The shape — findings → analysis → propose-then-wait — is consistent.)

**Talking points:**
- "The agent correlated `trace_id` across Datadog and Splunk via the custom topology MCP — no hardcoded correlation logic in the agent itself."
- "The dependency graph came from the catalog MCP, so blast-radius reasoning is data-driven."
- "Investigation: a few seconds. A human alt-tabbing between Datadog and Splunk: 10–20 minutes."

---

## Story Beat 4 — Propose, then Remediate (2:45 – 3:30)

**Narration:** "The agent proposes a runbook — it does **not** execute destructive actions autonomously. A human approves first. That gate is the governance story."

**The guardrail:** the system prompt forces the agent to call `topology__list_runbooks` and *present* its choice before it is allowed to call `topology__run_runbook`. It proposes `disable-chaos` and stops.

**Approve & remediate (operator runs the approved runbook):**
```bash
make reset-chaos
# this is exactly what the disable-chaos runbook does: POST /chaos/reset on the target(s)
```

**Expected output:** all 7 services report `reset OK (HTTP 201)`.

> **Bonus — AMP path:** in the WSO2 Agent Manager console the proposal appears as a pending
> approval card; clicking **Approve** lets the agent call `run_runbook` itself, and the
> SSE-streamed progress shows in the trace view.

**Talking point:** "Tool access ≠ permission to act. The propose-before-act gate is enforced regardless of how the agent is hosted."

---

## Story Beat 5 — Recovery (3:30 – 4:15)

**Narration:** "With chaos cleared, the mesh heals immediately."

**Show live — charges go back to all-success:**
```bash
for i in $(seq 1 12); do curl -s -o /dev/null -w "%{http_code} " -X POST http://localhost:9096/charge \
  -H "Content-Type: application/json" -d '{"amount":10,"currency":"USD","orderId":"r'$i'"}'; done; echo
# expect all 201s
```

> **Bonus — live SaaS:** Datadog p99 graph drops to baseline; Splunk 502 count returns to zero.

**Talking point:** "One OTel Collector fans telemetry to both backends — adding a destination is one exporter config change, no service restarts."

---

## Story Beat 6 — Postmortem Output (4:15 – 5:00)

**Narration:** "Re-run the agent (or ask it in chat) and it summarizes the incident end-to-end."

```bash
curl -s -X POST http://localhost:8092/chat \
  -H "Content-Type: application/json" \
  -d '{"message":"Summarize the payment-service incident: cause, blast radius, what fixed it.","sessionId":"demo-wrap"}' | jq -r .message
```

**Close:** "Alert to remediation in well under a minute. Correlated signals across Splunk and Datadog over MCP, a data-driven blast-radius graph, and a human approval gate on every destructive action — and the whole agent is itself observable."

---

## Recovery Procedures (if things go wrong)

| Problem | Fix |
|---------|-----|
| A POC service shows `unhealthy` | Healthchecks use `wget` (the Ballerina image has no `curl`); if a probe still fails, hit `/health` directly on the host port to confirm the service is actually fine |
| Agent returns `ANTHROPIC_API_KEY not set` | Set a real `sk-ant-` key in `compose/.env`, then `docker compose up -d --force-recreate devops-oversight-agent` |
| Chaos returns `000` / connection refused | You're hitting the wrong port — chaos is on host ports **9191–9197** (payment = **9196**), not 9099 (that's the in-container port) |
| Charges all 502 after reset | Reset may have raced the latency window; re-run `make reset-chaos` and wait ~5s |
| Agent not responding on 8092 | `docker compose logs devops-oversight-agent`; confirm listener on :8000 mapped to :8092 |
| Investigation hangs | The agent makes real Claude API calls (~30–60s with several tool calls); give it time, or tail the agent log to see tool calls progressing |
| Datadog/Splunk dashboards empty | Expected unless SaaS creds (`DD_API_KEY`, `DD_APP_KEY`, `SPLUNK_HEC_TOKEN`) are set — the mock-MCP demo does not need them |
| *(Bonus)* AMP console unreachable | `http://localhost:3000` (amp-admin/amp-admin); the AMP path is optional — fall back to this compose script |

**Absolute fallback:** pre-recorded screen capture from a clean `make rehearse` run.
