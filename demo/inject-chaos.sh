#!/usr/bin/env bash
# Inject the headline demo scenario: payment-service 502s + 2s latency.
# Usage: ./demo/inject-chaos.sh [service] [error-rate] [latency-ms] [duration-s]
set -euo pipefail

SERVICE=${1:-payment-service}
ERROR_RATE=${2:-0.3}
LATENCY_MS=${3:-2000}
DURATION_S=${4:-300}
CHAOS_TOKEN=${CHAOS_TOKEN:-dev-chaos-token}

# Strip -service suffix to get the compose service hostname.
HOST=${SERVICE%-service}
PORT=9099
BASE_URL="http://localhost:${PORT}"

echo "==> Injecting chaos into ${SERVICE}"
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
echo "Trigger agent: POST http://localhost:8080/investigate  body={\"service\":\"${SERVICE}\",\"severity\":\"P1\"}"
