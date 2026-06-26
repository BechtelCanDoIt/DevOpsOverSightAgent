#!/usr/bin/env bash
# Inject the headline demo scenario: payment-service 502s + 2s latency.
# Usage: ./demo/inject-chaos.sh [service] [error-rate] [latency-ms] [duration-s]
#
# Run from the HOST. Each service's internal chaos port (9099) is published to a
# distinct host port (9191-9197); we map service -> host port below.
set -euo pipefail

SERVICE=${1:-payment-service}
ERROR_RATE=${2:-0.3}
LATENCY_MS=${3:-2000}
DURATION_S=${4:-300}
CHAOS_TOKEN=${CHAOS_TOKEN:-dev-chaos-token}

# Strip -service suffix, then map to the published host chaos port.
HOST=${SERVICE%-service}
case "$HOST" in
  store)        PORT=9191 ;;
  customer)     PORT=9192 ;;
  order)        PORT=9193 ;;
  inventory)    PORT=9194 ;;
  invoice)      PORT=9195 ;;
  payment)      PORT=9196 ;;
  notification) PORT=9197 ;;
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
  -d "{\"rate\": ${ERROR_RATE}, \"status\": 502}" \
  && echo "[ok] error rate injected" || echo "[warn] error injection skipped"

echo ""
echo "Chaos active on ${SERVICE}. Run: make reset-chaos  to restore normal operation."
echo "Trigger agent: curl -X POST http://localhost:8092/investigate -H 'Content-Type: application/json' -d '{\"service\":\"${SERVICE}\",\"severity\":\"P1\"}'"
echo "          (or: make investigate)"
