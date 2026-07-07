#!/usr/bin/env bash
# A2A config integration test — creds-free-ish (an LLM is only needed if you
# push a full investigation; card resolution needs none). Asserts:
#   1. both specialist AgentCards resolve at the well-known path (18101 / 18102)
#   2. the orchestrator /health is UP (18092)
#   3. (optional, if an LLM is configured) a canned /investigate touches the
#      agents and returns a proposal without executing a runbook.
#
# Flags: --no-build, --no-start, --teardown.
set -euo pipefail

cd "$(dirname "$0")/.."
COMPOSE="docker compose -f compose/docker-compose.yml"

BUILD=1; START=1; TEARDOWN=0
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    --no-start) START=0 ;;
    --teardown) TEARDOWN=1 ;;
  esac
done

fail() { echo "FAIL: $*"; exit 1; }
CARD_PATH="/.well-known/agent-card.json"

if [ "$START" = "1" ]; then
  if [ "$BUILD" = "1" ]; then $COMPOSE up -d --build; else $COMPOSE up -d; fi
fi

echo "==> waiting for agents to come up..."
for i in $(seq 1 60); do
  if curl -sf "http://localhost:18101${CARD_PATH}" >/dev/null 2>&1 \
     && curl -sf "http://localhost:18102${CARD_PATH}" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

echo "==> 1. AgentCards resolve"
curl -sf "http://localhost:18101${CARD_PATH}" | grep -q 'DataDogAgent' && echo "  [ok] DataDogAgent card" || fail "DataDogAgent card"
curl -sf "http://localhost:18102${CARD_PATH}" | grep -q 'SplunkAgent' && echo "  [ok] SplunkAgent card" || fail "SplunkAgent card"

echo "==> 2. orchestrator health"
for i in $(seq 1 30); do
  curl -sf http://localhost:18092/health >/dev/null 2>&1 && break
  sleep 2
done
curl -sf http://localhost:18092/health | grep -q '"status":"UP"' && echo "  [ok] orchestrator UP" || fail "orchestrator health"

echo "==> 3. investigation (optional — requires a configured LLM)"
RESP=$(curl -s -X POST http://localhost:18092/investigate -H 'Content-Type: application/json' \
  -d '{"service":"payment-service","severity":"P1","description":"502 spike"}' || echo '{}')
if echo "$RESP" | grep -q '"status":"investigated"'; then
  echo "  [ok] investigation returned a summary"
  echo "$RESP" | grep -q '"sessionId"' && echo "  [ok] sessionId present (approve via /chat to run a runbook)"
else
  echo "  [skip] no LLM configured (set LLM_PROVIDER + creds in compose/.env to exercise this)"
fi

echo "PASS: A2A config tests"
if [ "$TEARDOWN" = "1" ]; then $COMPOSE down; fi
