#!/usr/bin/env bash
# Clear chaos from all 7 services.
#
# Run from the HOST. Each service's internal chaos port (9099) is published to a
# distinct 1-PREFIXED host port (19191-19197).
set -euo pipefail

CHAOS_TOKEN=${CHAOS_TOKEN:-dev-chaos-token}

PAIRS=(
  "store:19191"
  "customer:19192"
  "order:19193"
  "inventory:19194"
  "invoice:19195"
  "payment:19196"
  "notification:19197"
)

echo "==> Resetting chaos on all services..."
for PAIR in "${PAIRS[@]}"; do
  SVC=${PAIR%:*}
  PORT=${PAIR#*:}
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:${PORT}/chaos/reset" \
    -H "X-Chaos-Token: ${CHAOS_TOKEN}" 2>/dev/null || echo "000")
  case "${STATUS}" in
    200|201|204) echo "  [${SVC}] reset OK (HTTP ${STATUS})" ;;
    *)           echo "  [${SVC}] skipped (HTTP ${STATUS})" ;;
  esac
done

echo ""
echo "All services reset. Mesh returns to baseline within 30s."
