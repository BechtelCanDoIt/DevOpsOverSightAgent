# Known Issues & Recovery Procedures

## Compose Demo (Guaranteed Path)

### Agent not reachable on localhost:8092
**Symptom:** `curl -s http://localhost:8092/health` returns connection refused or timeout.

**Recovery:**
1. Check container status: `docker compose ps devops-oversight-agent`
2. If unhealthy, check logs: `docker compose logs devops-oversight-agent`
3. If build failed on `ANTHROPIC_API_KEY not set`, you hit the stale-jar VOLUME bug; rebuild with `docker compose build --no-cache devops-oversight-agent`
4. If network unreachable, the agent may be waiting for an MCP server to initialize — check that mcp-proxy, splunk-mock-mcp, and datadog-mock-mcp are UP

### Investigation returns "Investigation incomplete — max turns reached"
**Symptom:** `make investigate` returns `{"status":"investigated","summary":"Investigation incomplete — max turns reached."}`.

**Root cause:** Ollama models are non-deterministic about how many tool calls they make. The current `maxTurns` setting was too low for this particular model run.

**Recovery:**
1. Retry once — Ollama often completes in fewer turns on the next attempt.
2. If it fails repeatedly, switch to the Anthropic backend: set `LLM_PROVIDER=anthropic` + `ANTHROPIC_API_KEY=sk-ant-api03-…` in `compose/.env`, then `docker compose up -d devops-oversight-agent`.
3. maxTurns defaults to **40** (`configurable int agentMaxTurns` in `devops_oversight_agent.bal`; override with `AGENT_MAX_TURNS` in `compose/.env` — no rebuild needed). It was bumped from 30 for the Phase 6/7 backend expansion (more federated backends → more `discover_tools` turns). Do not reduce below 25 — Ollama non-determinism plus discovery overhead can consume up to 25 turns on some runs.

### Investigation hangs / takes >5 minutes
**Symptom:** `make investigate` returns HTTP 200 but takes a very long time.

**Root cause:** Local Ollama model investigations are sequential tool-call chains. With qwen3.5:9b, expect 1–3 minutes per investigation.

**Recovery options:**
1. **Speed up:** switch to Anthropic Claude (requires real API key): set `LLM_PROVIDER=anthropic` + `ANTHROPIC_API_KEY=sk-ant-api03-…` in compose/.env
2. **Wait it out:** tail the agent logs (`docker compose logs -f devops-oversight-agent`) to watch tool calls progress. The investigation is still running.

### Agent says "EXECUTION BLOCKED — human approval required … Approval token: RB-N"
**Symptom:** You ask the agent to run a runbook (or it proposes one during an investigation) and get back an `EXECUTION BLOCKED … Approval token: RB-N` message instead of the runbook running.

**This is expected — it is the human-approval gate working as designed** (Phase 4 §4.9, `code/agent/approval.bal`). The agent's dispatcher intercepts every `topology__run_runbook` call and never forwards it; the model cannot execute a runbook on its own.

**To proceed:** send a separate chat message `{"message":"approve RB-N"}` to `POST /chat` to execute, or `{"message":"deny RB-N"}` to cancel. Tokens are single-use — a repeated `approve` after success correctly reports "No pending runbook found."

### Agent returns "Tool error: connection refused" for MCPs
**Symptom:** Agent investigation completes but tool calls return connection errors.

**Recovery:**
1. Check the core MCP servers are healthy: `curl -s http://localhost:8290/health` (proxy — its response also lists per-backend status), `curl -s http://localhost:8400/health` (splunk-mock), `curl -s http://localhost:8401/health` (datadog-mock). The WSO2-product mocks (8402/8403/8404) are also up by default.
2. If any is unhealthy, restart the stack: `docker compose down && docker compose up -d`

### Chaos endpoints return connection refused or HTTP 408
**Symptom:** `make inject-chaos` returns `[warn] latency injection skipped (service not running?)` or `make reset-chaos` shows `skipped (HTTP 408)` or `skipped (HTTP 000000)`.

**Root cause:** A second Docker runtime (Colima agent-manager, Rancher Desktop, or another Lima VM) is running the same Compose stack and has grabbed ports 9191–9197 via its SSH port-forward before the primary runtime could.

**Diagnosis:**
```bash
lsof -nP -iTCP:9196 -sTCP:LISTEN
```
If you see `ssh` listed (not blank), another VM's Lima is intercepting the port.

**Recovery:**
1. Find which Docker context has the duplicate stack:
   ```bash
   DOCKER_HOST=unix:///Users/scottbechtel/.colima/agent-manager/docker.sock docker ps | grep payment
   ```
2. Stop the duplicate stack in that context:
   ```bash
   DOCKER_HOST=unix:///Users/scottbechtel/.colima/agent-manager/docker.sock \
     docker compose -f compose/docker-compose.yml down
   ```
3. Do a full cycle in the primary context to let Lima re-establish forwards:
   ```bash
   docker compose -f compose/docker-compose.yml down && docker compose -f compose/docker-compose.yml up -d
   ```

**Root cause of secondary port conflict:** You're likely hitting the wrong port (e.g., internal 9099 instead of host 9191–9197).

**Recovery:** The demo scripts auto-discover the host ports. Run `make inject-chaos` or `make reset-chaos` directly; do not hand-craft chaos URLs.

### Charges all return 502 after reset-chaos
**Symptom:** After running `make reset-chaos`, charges still fail.

**Root cause:** Chaos latency window (300s) may still be active; reset may not have propagated through the mesh yet.

**Recovery:** Wait 5–10 seconds and re-run `make reset-chaos` again. If it still fails, `docker compose restart payment-service` and wait 10s.

### Healthchecks show "unhealthy" for payload services
**Symptom:** `docker compose ps` shows a service as `unhealthy` (Exited).

**Root cause:** Healthchecks use `wget` (Ballerina image has no `curl`). If the probe is failing, it's usually a transient network glitch during startup.

**Recovery:** `docker compose restart <service>` and wait 15s. If it persists, check the service logs: `docker compose logs <service>`.

---

## AMP Demo (Bonus Path)

### AMP console unreachable
**Symptom:** `http://localhost:3000` returns "connection refused" or times out.

**Recovery:** The AMP cluster may be down or slow to start. Check: `kubectl get pods -n agent-manager` (if kind/k3d cluster is up). If the cluster is not running, fall back to the Compose demo.

### Agent pod shows "CrashLoopBackOff"
**Symptom:** Agent pod restarts repeatedly.

**Recovery:** Check logs: `kubectl logs -f -n agent-manager -l app=devops-oversight-agent`. Common causes:
- Missing Component or ComponentRelease CR (this is known; see [CLAUDE.md](CLAUDE.md) Phase 0)
- Agent cannot reach MCPs — ensure kind networking is wired correctly
- Fallback: run the demo on Compose instead

### Approved runbook reports success but chaos isn't cleared
**Symptom:** Operator sends `approve RB-N`, the agent replies `"…APPROVED and executed"`, but the target service is still degraded.

**Root cause:** The approval handler's `run_runbook` reached the proxy, but the proxy/backend could not reach the target service's chaos endpoint (a network routing issue — common in the kind cluster; the runbook's step log will show `call failed: …`).

**Recovery:** Fall back to the Compose demo (guaranteed to work), or reset chaos directly with `make reset-chaos` / `curl … /chaos/reset`. The AMP path is a bonus feature with higher operational complexity.

---

## Absolute Fallback

If you encounter an issue not listed above or recovery steps don't work, **use the pre-recorded demo video** (see `demo/recorded-run.mp4` if available). This proves the architecture and narrative to the audience without requiring live troubleshooting.

**Key talking points if you go to the recording:**
- "The demo runs end-to-end, as you see here — agent diagnoses payment-service chaos, proposes the fix, and recovers the mesh in under 5 minutes."
- "In production, the MCP servers would point to your live Splunk and Datadog instances, not the mocks we're running locally."
- "The agent itself is observable — its traces appear in the same Datadog and Splunk backends it queries, so you can audit every decision."

---

## Reporting New Issues

If you encounter a problem not in this list, please [open an issue](https://github.com/your-org/DevOpsOverSightAgent/issues) with:
- Steps to reproduce
- Docker version and Ballerina version (`bal version`)
- Output of `docker compose ps` and any relevant service logs
- Whether you're on the Compose path or AMP path
