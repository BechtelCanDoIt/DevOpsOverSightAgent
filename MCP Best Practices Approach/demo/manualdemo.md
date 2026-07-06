# Manual Demo Walkthrough

A step-by-step guide for running the DevOps Observability POC locally: start the stack, talk to the agent, inject a real incident, watch the agent diagnose it, then shut down cleanly.

**Prerequisites:** Docker running, Ollama running with `qwen3.5:9b` pulled (or `ANTHROPIC_API_KEY` set in `compose/.env`).

---

## 1. Start the stack

```bash
cd /path/to/DevOpsAgent

docker compose -f compose/docker-compose.yml up -d
```

First run builds all Ballerina images (~3–5 min). Subsequent runs start in seconds.

**Confirm everything is up:**

```bash
docker compose -f compose/docker-compose.yml ps
```

All services should show `Up` or `Up (healthy)`. Then confirm the agent is ready:

```bash
curl http://localhost:8092/health
# → {"status":"UP","service":"devops-oversight-agent"}
```

---

## 2. Baseline chat — no problems

Ask the agent a freeform question about the system. This exercises the tool-use loop against the MCP Proxy without any active incident.

```bash
curl -s -X POST http://localhost:8092/chat \
  -H "Content-Type: application/json" \
  -d '{
    "message": "What services are in the mesh and which ones have the most dependencies?",
    "sessionId": "demo-baseline"
  }' | jq .
```

Try a few more to get a feel for what the agent knows:

```bash
# Ask about a specific service
curl -s -X POST http://localhost:8092/chat \
  -H "Content-Type: application/json" \
  -d '{"message": "What does the payment-service do and what calls it?", "sessionId": "demo-baseline"}' | jq .

# Ask about observability
curl -s -X POST http://localhost:8092/chat \
  -H "Content-Type: application/json" \
  -d '{"message": "What Splunk and Datadog tools are available for investigating an incident?", "sessionId": "demo-baseline"}' | jq .
```

---

## 3. Baseline investigation — no problems

Trigger a structured investigation before anything is broken. The agent should find nothing alarming.

```bash
curl -s -X POST http://localhost:8092/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "service": "payment-service",
    "severity": "P3",
    "description": "Routine health check — no alerts active",
    "id": "INC-000"
  }' | jq .
```

---

## 4. Inject chaos — create a P1 incident

Inject 502 errors into payment-service at 80% rate for 5 minutes. This cascades: order-service calls payment, so checkouts fail across the board.

```bash
curl -s -X POST http://localhost:9196/chaos/error \
  -H "X-Chaos-Token: dev-chaos-token" \
  -H "Content-Type: application/json" \
  -d '{"rate": 0.8, "status": 502, "duration_s": 300}'
```

Optionally stack latency on top for a more realistic scenario:

```bash
curl -s -X POST http://localhost:9196/chaos/latency \
  -H "X-Chaos-Token: dev-chaos-token" \
  -H "Content-Type: application/json" \
  -d '{"ms": 1500, "duration_s": 300}'
```

Wait ~15–20 seconds for load-gen to generate error traffic.

---

## 5. Chat during incident

Ask the agent to explain what's happening in plain language:

```bash
curl -s -X POST http://localhost:8092/chat \
  -H "Content-Type: application/json" \
  -d '{
    "message": "We are seeing checkout failures. What do you see in payment-service right now?",
    "sessionId": "demo-incident"
  }' | jq .
```

```bash
curl -s -X POST http://localhost:8092/chat \
  -H "Content-Type: application/json" \
  -d '{
    "message": "Are there any upstream or downstream services affected by the payment-service issues?",
    "sessionId": "demo-incident"
  }' | jq .
```

---

## 6. Trigger a P1 investigation during incident

This is the headline demo flow. The agent correlates signals from the MCP Proxy (topology + mock Splunk/Datadog data), identifies the root cause, and proposes a runbook.

```bash
curl -s -X POST http://localhost:8092/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "service": "payment-service",
    "severity": "P1",
    "description": "502 spike — customers cannot complete checkout, order-service reporting upstream errors",
    "id": "INC-001"
  }' | jq .
```

The response will include:
- Root cause summary
- Affected services (payment + order cascade)
- Proposed runbook steps before any action is taken

---

## 7. Reset chaos

```bash
curl -s -X POST http://localhost:9196/chaos/reset \
  -H "X-Chaos-Token: dev-chaos-token"
```

Or...
```bash
curl -s -X POST http://localhost:8290/mcp \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "tools/call",
    "params": {
      "name": "run_runbook",
      "arguments": {
        "id": "disable-chaos",
        "params": {"service": "payment-service"}
      }
    },
    "id": 1
  }' | jq .
```

Or...
Just ask the model to do it
````bash
curl -s -X POST http://localhost:8092/chat \
  -H "Content-Type: application/json" \
  -d '{"message": "Run the disable-chaos runbook for payment-service", "sessionId": "demo-recovery"}' | jq .
````

Confirm recovery:

```bash
curl -s -X POST http://localhost:8092/chat \
  -H "Content-Type: application/json" \
  -d '{"message": "Is payment-service healthy now?", "sessionId": "demo-recovery"}' | jq .
```

---

## 8. Other chaos scenarios to explore

**Latency-only (no errors) — simulates a slow dependency:**
```bash
curl -s -X POST http://localhost:9196/chaos/latency \
  -H "X-Chaos-Token: dev-chaos-token" \
  -H "Content-Type: application/json" \
  -d '{"ms": 3000, "duration_s": 120}'
```

**503 at low rate — intermittent failures, harder to spot:**
```bash
curl -s -X POST http://localhost:9196/chaos/error \
  -H "X-Chaos-Token: dev-chaos-token" \
  -H "Content-Type: application/json" \
  -d '{"rate": 0.2, "status": 503, "duration_s": 180}'
```

Then ask the agent:
```bash
curl -s -X POST http://localhost:8092/chat \
  -H "Content-Type: application/json" \
  -d '{"message": "We are seeing intermittent failures on checkout but no clear spike. Can you investigate?", "sessionId": "demo-intermittent"}' | jq .
```

---

## 9. Check agent and service logs

```bash
# Agent reasoning trace
docker compose -f compose/docker-compose.yml logs devops-oversight-agent --tail=50

# MCP Proxy audit log
docker compose -f compose/docker-compose.yml logs mcp-proxy --tail=50

# Payment service chaos state
docker compose -f compose/docker-compose.yml logs payment --tail=20
```

---

## 10. Shut down

```bash
# Stop all services (keeps Postgres volume — data survives restart)
docker compose -f compose/docker-compose.yml down

# Stop and wipe all data (fresh slate next time)
docker compose -f compose/docker-compose.yml down -v
```

---

## Port reference

| Service | Host port | Purpose |
|---------|-----------|---------|
| Agent | `8092` | `/health`, `/chat`, `/investigate`, `/webhook` |
| MCP Proxy | `8290` | MCP Streamable HTTP endpoint |
| Splunk mock MCP | `8400` | Mock Splunk tool responses |
| Datadog mock MCP | `8401` | Mock Datadog tool responses |
| Payment chaos | `9196` | `/chaos/error`, `/chaos/latency`, `/chaos/reset` |
| OTel Collector | `4317` / `4318` | OTLP gRPC / HTTP |
| Postgres | `5432` | Direct DB access |
| Redis | `6379` | Direct cache access |
| NATS | `4222` / `8222` | Client / monitoring |
| Jaeger UI | `16686` | Local trace UI (`--profile dev` only) |
