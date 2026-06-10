# Demo Script — DevOps Observability POC
**Total target runtime: 5 minutes**
Presenter: solo or paired (one drives terminal, one narrates).

---

## Pre-demo Checklist (5 min before showtime)

- [ ] `make demo-up` — confirm all 8 containers are `Up` (`docker compose ps`)
- [ ] Open three windows side-by-side:
  1. Terminal (commands)
  2. Datadog APM / Service Map — filtered to `env:demo`
  3. Splunk Search — query: `index=devops sourcetype=otel earliest=-15m`
- [ ] WSO2 Agent Manager console at `http://localhost:3000` — agent listed and `RUNNING`
- [ ] Browser tab: `http://localhost:8080` (agent HTTP trigger endpoint)
- [ ] Verify baseline: `curl -s http://localhost:9090/health | jq .` returns `{"status":"ok"}` for store and payment
- [ ] Set `CHAOS_TOKEN=dev-chaos-token` in your shell (already default in scripts)
- [ ] Have `demo/script.md` open on a second monitor for reference

---

## Story Beat 1 — Inject Chaos (0:00 – 0:45)

**Narration:** "Our payment service is about to start misbehaving — 30% of requests returning HTTP 502 with 2 seconds of added latency. This is a realistic Saturday-afternoon incident."

**Command (run live):**
```bash
make inject-chaos
# or directly:
./demo/inject-chaos.sh payment-service 0.3 2000 300
```

**Expected output:**
```
==> Injecting chaos into payment-service
    Error rate: 0.3 (HTTP 502)   Latency: 2000ms for 300s
[ok] latency injected
[ok] error rate injected
Chaos active on payment-service. Run: make reset-chaos  to restore normal operation.
```

**Point at:** load-gen logs streaming errors — `docker compose logs -f load-gen | grep 502`

---

## Story Beat 2 — Alert Fires (0:45 – 1:15)

**Narration:** "Within 30 seconds the OTel Collector forwards spans to both Datadog and Splunk. Datadog fires a monitor: payment-service p99 latency > 1500 ms. Splunk triggers an alert on 5xx rate > 10%."

**Show on screen:**
- Datadog: open the `payment-service` APM service page — p99 latency graph spiking
- Splunk: run `index=devops service=payment-service status>=500 | stats count by status` — show 502 count climbing
- Agent Manager console: the incoming webhook fires; agent status flips to `INVESTIGATING`

**Talking point:** "Both signals are independent. Neither tool alone knows the full story — latency in Datadog, error codes in Splunk. The agent correlates them."

---

## Story Beat 3 — Agent Investigates (1:15 – 2:45)

**Narration:** "The agent receives the P1 alert, queries both MCP servers in parallel, and reasons across the combined signal set."

**Trigger the agent manually (if webhook not wired yet):**
```bash
curl -s -X POST http://localhost:8080/investigate \
  -H "Content-Type: application/json" \
  -d '{"service":"payment-service","severity":"P1"}' | jq .
```

**Show in Agent Manager trace view (amp-trace-observer):**
1. `tool_call: splunk_mcp.search_logs` — query for payment-service errors last 15 min
2. `tool_call: datadog_mcp.get_traces` — p99 latency for payment-service
3. `tool_call: catalog_mcp.get_service` — pull dependency graph; order-service depends on payment-service
4. `tool_call: splunk_mcp.search_logs` — check order-service for upstream cascade
5. Agent reasoning step (visible in WSO2 trace): "Root cause: payment-service chaos toggle active. 30% HTTP 502 + 2s latency. Upstream impact: order-service checkout flow degraded. Recommended runbook: disable-chaos on payment-service."

**Talking points:**
- "Notice the agent correlates `trace_id` across both tools — the same span shows up in Datadog APM and Splunk logs."
- "The catalog MCP gave the agent the dependency graph without any hardcoded logic in the agent itself."
- "Total investigation time: ~15 seconds. A human SRE would take 10–20 minutes."

---

## Story Beat 4 — Remediation (2:45 – 3:30)

**Narration:** "The agent proposes a runbook. It does not execute autonomously — it surfaces a human-approval gate."

**Show in Agent Manager console:**
- Pending approval card: "Execute runbook `disable-chaos` on `payment-service`?"
- Click **Approve**

**Behind the scenes (agent executes):**
```bash
# Agent POSTs to chaos reset endpoint:
POST http://localhost:9099/chaos/reset
X-Chaos-Token: dev-chaos-token
```

**Talking point:** "WSO2 Agent Manager enforces the approval gate. The agent has tool access but cannot self-approve safety-critical actions. This is the key governance story."

---

## Story Beat 5 — Recovery (3:30 – 4:15)

**Narration:** "With chaos cleared, the mesh heals within one scrape interval — 30 seconds."

**Show live:**
- Datadog: p99 latency graph dropping back to baseline (~50 ms)
- Splunk: 502 count falls to zero; `index=devops service=payment-service | timechart count by status` returns to all-200s

**Optional — show load-gen recovering:**
```bash
docker compose logs -f load-gen | grep -E "(200|502)" | tail -20
```

**Talking point:** "The OTel Collector is the single telemetry fan-out. One exporter config change — no agent restart needed to add a new destination."

---

## Story Beat 6 — Postmortem Output (4:15 – 5:00)

**Narration:** "The agent writes a structured postmortem automatically."

**Show agent output (print or paste into terminal):**
```json
{
  "incident_id": "INC-2024-001",
  "service": "payment-service",
  "root_cause": "chaos toggle active — 30% HTTP 502, +2000ms latency",
  "detection_time_s": 28,
  "investigation_time_s": 14,
  "remediation": "disable-chaos runbook executed after human approval",
  "upstream_impact": ["order-service checkout flow (degraded, not down)"],
  "signals_used": ["datadog:traces", "splunk:logs"],
  "trace_ids_correlated": 47,
  "sla_breach": false,
  "postmortem_owner": "payments-team",
  "follow_up": ["add chaos-detection metric to Datadog monitor", "add runbook to catalog"]
}
```

**Close:** "End-to-end: alert to remediation in under 60 seconds, with a full audit trail in WSO2 Agent Manager, correlated signals across Splunk and Datadog, and a human approval gate on every destructive action."

---

## Recovery Procedures (if things go wrong)

| Problem | Fix |
|---------|-----|
| Container not starting | `docker compose logs <service>` — check port conflicts; `make demo-down && make demo-up` |
| Chaos injection returns `000` / connection refused | Service chaos port (9099) not mapped — check `compose/docker-compose.yml` port bindings |
| Agent not receiving alert | Trigger manually: `curl -X POST http://localhost:8080/investigate -d '{"service":"payment-service","severity":"P1"}'` |
| Datadog shows no traces | Check OTel Collector: `docker compose logs otel-collector | grep datadog` — missing `DD_API_KEY` env var |
| Splunk shows no events | Verify HEC token: `docker compose logs otel-collector | grep splunk_hec` |
| WSO2 console unreachable | `amctl status`; if down: `amctl restart` or navigate directly to `http://localhost:3000` |
| p99 not spiking visibly | Increase load: `curl -X POST http://localhost:9090/load/scale -d '{"rps":50}'` |
| Demo runs long | Skip Beat 6 (postmortem); jump straight from recovery graph to closing statement |

**Absolute fallback:** pre-recorded screen capture at `demo/recording.mp4` (record during rehearsal with `make rehearse`).
