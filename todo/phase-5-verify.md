# Phase 5 — Demo rehearsal & verification

**Goal:** turn the moving parts from Phases 0–4 into a tight, repeatable demo. Identify what breaks, rehearse the script, and write the recovery procedure for when something goes wrong on stage.

## The headline scenario — incident triage

**Setup (pre-demo):** mesh is up, load-gen is in `baseline` mode, agent is deployed and idle. Datadog and Splunk dashboards are pre-loaded in browser tabs.

**Story beats:**
1. **Inject** — operator triggers `payment-service` chaos: 30% 502 rate + 2s latency. Mesh starts degrading.
2. **Alert** — Datadog monitor (pre-configured) fires within 60s, webhook hits the agent.
3. **Investigation (live narration)** — agent's reasoning visible in `amp-trace-observer`:
   - Pulls recent error-rate metrics from Datadog (`get_datadog_metric` / error-tracking)
   - Identifies `payment-service` as the spike origin
   - Calls Ballerina MCP `get_dependencies("payment-service", "downstream")` to assess blast radius
   - Pulls a sample trace from Datadog, calls `correlate_trace`, jumps to the matching Splunk logs
   - Notes the logs show timeouts to mock-bank
   - Calls `find_recent_deploys("payment-service")` — finds nothing, rules out deploy
   - Suspects chaos / external dependency, **proposes** `disable-chaos` runbook
4. **Remediation (human-in-the-loop)** — operator approves the runbook in the agent console.
5. **Recovery** — agent calls `run_runbook("disable-chaos", { service: "payment-service" })`, mesh recovers.
6. **Postmortem (cherry on top)** — agent generates a markdown postmortem summarizing what happened, what it did, links to the traces. Slide-ready.

Total runtime target: **5 minutes** end-to-end.

## Tasks

### 5.1 Pre-flight checklist
- [x] All compose services healthy (`docker compose ps`)
- [ ] kind cluster up and Agent Manager pods running
- [x] Browser tabs pre-loaded: `amp-console`, Datadog APM, Splunk search, Ballerina MCP inspector
- [x] Load-gen in `baseline` for at least 10 minutes — gives Datadog enough data to call the anomaly an anomaly
- [x] Chaos endpoints are *reset* (`/chaos/reset` on all seven services)
- [x] Agent is "warm" — one throwaway invocation to make sure LLM API keys are valid and MCP connections are live

### 5.2 Rehearsal — run it three times
Each pass surfaces different problems:
- [x] **Pass 1:** find the obvious bugs (wrong URLs, missing tools, prompts that confuse the agent)
- [x] **Pass 2:** time it — anything slower than 90s of agent reasoning is too slow for a live demo, tighten the prompt
- [ ] **Pass 3:** record it as the fallback video

### 5.3 Failure modes & recovery
For each, write a one-paragraph "what to do if this happens on stage":
- [x] LLM API rate-limited or down → fall back to recorded video
- [x] Datadog ingest lag → narrate over it, "as you can see, the alert *would have* fired here"
- [x] Agent picks the wrong runbook → praise it for *proposing* before *acting* (turns a bug into a feature)
- [x] Compose service crashes mid-demo → `docker compose restart <svc>` script committed to repo
- [x] kind cluster networking glitch → keep a recorded run available

### 5.4 Demo script
- [x] `demo/script.md` with verbatim narration cues + exact commands to run
- [x] `demo/inject-chaos.sh` — the one-liner the operator hits to start the scenario (targets `payment-service` for the headline)
- [x] `demo/reset.sh` — restores the system to a known-good state between rehearsals; loops `/chaos/reset` over all seven services

### 5.5 Verification beyond the headline scenario
Confirm the platform handles two more scenarios end-to-end (not necessarily live-demoed):
- [ ] **Slow query regression** — chaos injects DB latency in `inventory-service` → agent diagnoses it as DB-bound (vs network-bound) by looking at span breakdowns
- [ ] **Async backlog** — `notification-service` chaos slows consumption → agent identifies NATS backlog via Datadog, recommends a scale-up runbook

Why bother? Because the live demo audience always asks "can it do anything else?" and a 30-second response showing two more diagnoses is the difference between a curiosity and a product.

### 5.6 Hardening checklist
- [x] No secrets in any committed file (`git secrets --scan`)
- [x] All `.env.example` files complete
- [x] `docker compose down -v && docker compose up -d` works from a clean machine in under 5 minutes
- [x] `Makefile` with `make demo-up`, `make demo-mock-up`, `make demo-down`, `make rehearse`

## Deliverables

- A rehearsed 5-minute demo
- A recorded fallback video
- `demo/script.md` and the inject/reset shell scripts
- A `KNOWN_ISSUES.md` documenting what could go wrong and how to recover

## Exit criteria

You can hand the repo to a colleague who's never seen it, point them at `todo/README.md`, and they can stand up the full demo and run the rehearsal in under an hour. That's the bar for a POC that proves the architecture rather than just demos the agent.
