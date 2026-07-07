#!/usr/bin/env bash
# Inject the headline demo scenario: payment-service 502s + 2s latency.
# Usage: ./demo/inject-chaos.sh [service] [error-rate] [latency-ms] [duration-s]
#
# Run from the HOST. Each service's internal chaos port (9099) is published to a
# distinct 1-PREFIXED host port (19191-19197) so this stack runs side-by-side
# with the Ballerina stack (which uses 9191-9197).
#
# NOTE: unlike the Ballerina demo script, the /chaos/error call below passes
# duration_s — the reference omitted it, so injected errors silently expired
# after the 60s default even when a longer duration was requested.
set -euo pipefail

SERVICE=${1:-payment-service}
ERROR_RATE=${2:-0.3}
LATENCY_MS=${3:-2000}
DURATION_S=${4:-300}
CHAOS_TOKEN=${CHAOS_TOKEN:-dev-chaos-token}

HOST=${SERVICE%-service}
case "$HOST" in
  store)        PORT=19191 ;;
  customer)     PORT=19192 ;;
  order)        PORT=19193 ;;
  inventory)    PORT=19194 ;;
  invoice)      PORT=19195 ;;
  payment)      PORT=19196 ;;
  notification) PORT=19197 ;;
  *) echo "Unknown service '${SERVICE}'. Expected one of: store|customer|order|inventory|invoice|payment|notification (-service)"; exit 1 ;;
esac
BASE_URL="http://localhost:${PORT}"

echo "==> Injecting chaos into ${SERVICE} (host port ${PORT})"
echo "    Error rate: ${ERROR_RATE} (HTTP 502)   Latency: ${LATENCY_MS}ms for ${DURATION_S}s"
echo ""

curl -sf -X POST "${BASE_URL}/chaos/latency" \
  -H "Content-Type: application/json" \
  -H "X-Chaos-Token: ${CHAOS_TOKEN}" \
  -d "{\"ms\": ${LATENCY_MS}, \"duration_s\": ${DURATION_S}}" \
  && echo "[ok] latency injected" || echo "[warn] latency injection skipped (service not running?)"

curl -sf -X POST "${BASE_URL}/chaos/error" \
  -H "Content-Type: application/json" \
  -H "X-Chaos-Token: ${CHAOS_TOKEN}" \
  -d "{\"rate\": ${ERROR_RATE}, \"status\": 502, \"duration_s\": ${DURATION_S}}" \
  && echo "[ok] error rate injected" || echo "[warn] error injection skipped"

echo ""
echo "Chaos active on ${SERVICE}. Run: make reset-chaos  to restore normal operation."
echo "Trigger agent: curl -X POST http://localhost:18092/investigate -H 'Content-Type: application/json' -d '{\"service\":\"${SERVICE}\",\"severity\":\"P1\"}'"
echo "          (or: make investigate)"
