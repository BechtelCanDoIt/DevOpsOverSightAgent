#!/usr/bin/env bash
# Clear chaos from all 7 services.
set -euo pipefail

CHAOS_TOKEN=${CHAOS_TOKEN:-dev-chaos-token}
SERVICES=(store customer order inventory invoice payment notification)

echo "==> Resetting chaos on all services..."
for SVC in "${SERVICES[@]}"; do
  PORT=9099
  STATUS=$(curl -sf -o /dev/null -w "%{http_code}" -X POST "http://localhost:${PORT}/chaos/reset" \
    -H "X-Chaos-Token: ${CHAOS_TOKEN}" 2>/dev/null || echo "000")
  [ "${STATUS}" = "200" ] && echo "  [${SVC}] reset OK" || echo "  [${SVC}] skipped (HTTP ${STATUS})"
done

echo ""
echo "All services reset. Mesh returns to baseline within 30s."
