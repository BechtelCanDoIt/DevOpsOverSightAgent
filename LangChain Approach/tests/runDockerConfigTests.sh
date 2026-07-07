#!/usr/bin/env bash
# Docker-config integration test — creds-free, mirrors the Ballerina
# runDockerConfigTests.sh. Brings up the mesh + mock MCP servers and asserts:
#   1. all 7 mesh services report /health UP (host ports 19091-19097)
#   2. both mock MCP servers report /health UP (18400 / 18401)
#   3. the chaos cycle works end to end on payment-service:
#        inject rate=1.0 -> POST /charge returns 502 chaos-injected -> reset -> 200 approved
#
# Flags: --no-build (skip image build), --no-start (assume stack is up),
#        --teardown (compose down at the end).
set -euo pipefail

cd "$(dirname "$0")/.."
COMPOSE="docker compose -f compose/docker-compose.yml"
CHAOS_TOKEN="${CHAOS_TOKEN:-dev-chaos-token}"

BUILD=1; START=1; TEARDOWN=0
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    --no-start) START=0 ;;
    --teardown) TEARDOWN=1 ;;
  esac
done

fail() { echo "FAIL: $*"; exit 1; }

if [ "$START" = "1" ]; then
  if [ "$BUILD" = "1" ]; then $COMPOSE up -d --build; else $COMPOSE up -d; fi
fi

echo "==> waiting for mesh + mocks to come up..."
for i in $(seq 1 60); do
  if curl -sf http://localhost:19096/health >/dev/null 2>&1 \
     && curl -sf http://localhost:18400/health >/dev/null 2>&1 \
     && curl -sf http://localhost:18401/health >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

echo "==> 1. mesh health"
declare -A MESH=( [store]=19091 [customer]=19092 [order]=19093 [inventory]=19094 [invoice]=19095 [payment]=19096 [notification]=19097 )
for svc in "${!MESH[@]}"; do
  curl -sf "http://localhost:${MESH[$svc]}/health" | grep -q '"status":"UP"' \
    && echo "  [ok] ${svc}-service UP" || fail "${svc}-service not UP"
done

echo "==> 2. mock MCP health"
curl -sf http://localhost:18400/health | grep -q 'splunk-mock-mcp' && echo "  [ok] splunk-mock-mcp UP" || fail "splunk-mock-mcp"
curl -sf http://localhost:18401/health | grep -q 'datadog-mock-mcp' && echo "  [ok] datadog-mock-mcp UP" || fail "datadog-mock-mcp"

echo "==> 3. chaos cycle on payment-service"
curl -sf -X POST http://localhost:19196/chaos/error \
  -H "X-Chaos-Token: ${CHAOS_TOKEN}" -H 'Content-Type: application/json' \
  -d '{"rate":1.0,"status":502,"duration_s":60}' >/dev/null || fail "inject error"
CODE=$(curl -s -o /tmp/charge_body -w "%{http_code}" -X POST http://localhost:19096/charge \
  -H 'Content-Type: application/json' -d '{"amount":19.99,"currency":"USD","orderId":"ORD-TEST"}')
grep -q 'chaos-injected' /tmp/charge_body && [ "$CODE" = "502" ] \
  && echo "  [ok] /charge returned 502 chaos-injected" || fail "expected 502 chaos-injected, got ${CODE}"
curl -sf -X POST http://localhost:19196/chaos/reset -H "X-Chaos-Token: ${CHAOS_TOKEN}" >/dev/null || fail "reset"
CODE=$(curl -s -o /tmp/charge_body -w "%{http_code}" -X POST http://localhost:19096/charge \
  -H 'Content-Type: application/json' -d '{"amount":19.99,"currency":"USD","orderId":"ORD-TEST"}')
[ "$CODE" = "201" ] && grep -q 'approved' /tmp/charge_body \
  && echo "  [ok] /charge recovered to 201 approved" || fail "expected 201 approved after reset, got ${CODE}"

echo "PASS: docker-config tests"
if [ "$TEARDOWN" = "1" ]; then $COMPOSE down; fi
