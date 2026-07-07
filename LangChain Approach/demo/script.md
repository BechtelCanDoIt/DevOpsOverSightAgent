# Demo Script — DevOps Observability POC (LangChain / A2A)
**Total target runtime: 5 minutes**
Presenter: solo or paired (one drives terminal, one narrates).

> **Run mode.** Docker Compose, creds-free. The orchestrator (**DevOpsOverSightAgent**) runs on
> `:18092` and delegates to two specialist agents over **A2A** — **DataDogAgent** (`:18101`) and
> **SplunkAgent** (`:18102`) — each of which reaches its platform through a dedicated **MCP client**
> talking to a **mock** MCP server. The proof is the orchestrator's own cross-signal reasoning,
> diagnosis, and proposed runbook.
>
> **Ports are 1-prefixed** so this stack runs side-by-side with the Ballerina "MCP Best Practices"
> stack. **Mock vs. live is a pure env-var swap** (`SPLUNK_MCP_URL` / `DATADOG_MCP_URL`, plus auth
> headers). **LLM is configurable** via `LLM_PROVIDER` (`anthropic` default, or creds-free `ollama`).
> A local-model investigation runs many sequential + A2A tool-call turns, so it takes ~1–2 min.

---

## Component reference (verified ports)

| Thing | URL | Notes |
|---|---|---|
| Orchestrator (DevOpsOverSightAgent) | `http://localhost:18092` | `/health`, `/investigate`, `/chat`, `/webhook/alert` (listener :8000 in-container) |
| DataDogAgent (A2A) | `http://localhost:18101` | AgentCard at `/.well-known/agent-card.json` |
| SplunkAgent (A2A) | `http://localhost:18102` | AgentCard at `/.well-known/agent-card.json` |
| Datadog mock MCP | `http://localhost:18401` | `/mcp` (streamable-http), `/health` |
| Splunk mock MCP | `http://localhost:18400` | `/mcp` (streamable-http), `/health` |
| payment-service | `http://localhost:19096` | business API (`/charge`, `/health`) |
| payment chaos | `http://localhost:19196` | `/chaos/latency\|error\|reset` (token-gated) |
| mesh chaos ports | `19191`–`19197` | store…notification, in that order |

---

## Pre-demo Checklist (5 min before showtime)

- [ ] Stack up: `make demo-up` (builds + starts everything).
- [ ] Orchestrator + specialists healthy:
  ```bash
  curl -s http://localhost:18092/health; echo
  curl -s http://localhost:18101/.well-known/agent-card.json | grep -o '"name":"[^"]*"' | head -1
  curl -s http://localhost:18102/.well-known/agent-card.json | grep -o '"name":"[^"]*"' | head -1
  ```
- [ ] Mock MCPs healthy: `for p in 18400 18401; do curl -s http://localhost:$p/health; echo; done`
- [ ] LLM reachable (Anthropic default: `ANTHROPIC_API_KEY` set; or Ollama: model pulled).
- [ ] Baseline payment works:
  ```bash
  curl -s -o /dev/null -w "charge -> HTTP %{http_code}\n" -X POST http://localhost:19096/charge \
    -H "Content-Type: application/json" -d '{"amount":42.50,"currency":"USD","orderId":"warmup"}'
  # expect HTTP 201
  ```
- [ ] Two terminals: one to drive, one tailing `docker compose -f compose/docker-compose.yml logs -f devops-oversight-agent`.
- [ ] *(Bonus)* Datadog APM + Splunk Search tabs — only with SaaS creds + the `--profile saas` overlay.

---

## Story Beat 1 — Inject Chaos (0:00 – 0:45)

**Narration:** "Our payment service starts misbehaving — 80% of requests return HTTP 502 with 2s
added latency. A realistic Saturday-afternoon incident."

```bash
./demo/inject-chaos.sh payment-service 0.8 2000 300
```

Confirm the fault is live (expect a 502 with a `chaos-injected` body):
```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:19096/charge \
  -H 'Content-Type: application/json' -d '{"amount":19.99,"currency":"USD","orderId":"probe"}'
```

## Story Beat 2 — Signals Diverge (0:45 – 1:15)

**Narration:** "The failure shows up in two silos at once — Datadog sees the error-rate and latency
spike on payment-service; Splunk sees the 502 log lines and the order-service cascade. Normally an
engineer would swivel-chair between them."

## Story Beat 3 — Investigate (1:15 – 3:30)

**Narration:** "Instead we ask the orchestrator. It delegates to the Datadog specialist and the
Splunk specialist over A2A, correlates by trace_id locally, checks the dependency blast radius and
recent deploys, and proposes a fix."

```bash
make investigate      # POST /investigate {service:payment-service, severity:P1}
```

Watch the orchestrator log: `ask_datadog_agent` → monitors + metrics + a `trace_id`;
`topology__correlate_trace` → Datadog URL + Splunk SPL; `ask_splunk_agent` → matching 502 log
events; `topology__find_recent_deploys` (none) → **chaos** heuristic; then it proposes the
`disable-chaos` runbook and **stops**. The response `summary` ends with a `sessionId` and the
approval instruction.

## Story Beat 4 — Approve & Remediate (3:30 – 4:15)

**Narration:** "Propose-before-act is a hard gate — the agent physically cannot run a runbook until
a human approves. We approve on that session."

```bash
# use the sessionId from the /investigate summary:
curl -s -X POST http://localhost:18092/chat -H 'Content-Type: application/json' \
  -d '{"message":"approve","sessionId":"inv-XXXXXXXX-..."}' | python3 -m json.tool
```

The graph resumes, runs `disable-chaos` (POST `/chaos/reset` on payment-service), and reports the steps.

## Story Beat 5 — Recover & Postmortem (4:15 – 5:00)

```bash
curl -s -o /dev/null -w "charge -> HTTP %{http_code}\n" -X POST http://localhost:19096/charge \
  -H 'Content-Type: application/json' -d '{"amount":19.99,"currency":"USD","orderId":"recovered"}'
# expect HTTP 201
```

Ask for a postmortem: `curl -s -X POST http://localhost:18092/chat -d '{"message":"give me a 3-line postmortem","sessionId":"inv-XXXX..."}'`

**Belt-and-suspenders reset:** `make reset-chaos`.

---

## Recovery procedures (if something wobbles live)

- **LLM down / slow:** fall back to a pre-recorded run; or switch `LLM_PROVIDER` to a reachable
  backend and `make demo-down && make demo-up`.
- **A2A card not resolving:** the orchestrator retries card resolution at startup; give the
  specialists a few more seconds, or `docker compose restart datadog-agent splunk-agent`.
- **Agent proposes the wrong runbook:** that's still a win — praise the propose-before-act gate and
  reject: `{"message":"reject","sessionId":"..."}`.
- **Compose crash:** `make demo-down && make demo-up`.
- **Port collision:** another local Postgres/Redis may hold 15432/16379 — `lsof -nP -iTCP:16379`.
