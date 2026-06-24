#!/usr/bin/env bash
# runTests.sh — bring up the infra `bal test` needs, run tests for every
# Ballerina package under generate/, print a per-service results table, and
# tear the infra back down.
#
# Why this script exists: each service's module-level Postgres/Redis/NATS
# client is initialised at module load (see CONVENTIONS.md). `bal test`
# triggers that init, so without the infra running it crashes before any
# test executes. This script handles that lifecycle.
#
# Usage:
#   ./runTests.sh                # run all twelve packages
#   ./runTests.sh order payment  # run just the listed packages
#   KEEP_UP=1 ./runTests.sh      # leave Postgres/Redis/NATS up after tests
#   BAL=/path/to/bal ./runTests.sh
#
# Requires: docker, docker compose, and the Ballerina toolchain (Swan Lake
# 2201.13.x). Default `bal` path matches CONVENTIONS.md.

set -uo pipefail
# NOTE: no `-e` — we want to capture each service's exit code, not bail out
# on the first failure.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

BAL="${BAL:-/Library/Ballerina/bin/bal}"
COMPOSE_FILE="compose/docker-compose.yml"
INFRA_SERVICES=(postgres redis nats)
ALL_SERVICES=(order payment inventory notification customer store invoice load-gen \
              agent mcp-server splunk-mock-mcp datadog-mock-mcp)

# Allow narrowing to a subset of services via positional args.
if [ "$#" -gt 0 ]; then
  SERVICES=("$@")
else
  SERVICES=("${ALL_SERVICES[@]}")
fi

# ── Preflight ───────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found on PATH" >&2
  exit 2
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: 'docker compose' v2 plugin not found" >&2
  exit 2
fi
# Check the daemon actually responds, not just that the CLI is installed.
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: cannot reach the Docker daemon at /var/run/docker.sock" >&2
  echo "       Start Docker Desktop (or 'systemctl start docker' on Linux) and rerun." >&2
  exit 2
fi
if [ ! -x "$BAL" ] && ! command -v "$BAL" >/dev/null 2>&1; then
  echo "ERROR: bal toolchain not found at '$BAL'" >&2
  echo "       set BAL=/path/to/bal or install Ballerina 2201.13.x" >&2
  exit 2
fi
if [ ! -f "$COMPOSE_FILE" ]; then
  echo "ERROR: compose file '$COMPOSE_FILE' not found (run from repo root)" >&2
  exit 2
fi

# Silence compose's "variable not set" warnings for env vars only used by the
# optional `saas` / `dev` profiles (not the infra services we bring up here).
export DD_API_KEY="${DD_API_KEY:-}"
export DD_APP_KEY="${DD_APP_KEY:-}"
export DD_SITE="${DD_SITE:-}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-pocpass}"
export GIT_COMMIT="${GIT_COMMIT:-unknown}"
export CHAOS_TOKEN="${CHAOS_TOKEN:-dev-chaos-token}"

# ── Teardown trap ───────────────────────────────────────────────────────────
teardown() {
  if [ "${KEEP_UP:-0}" = "1" ]; then
    echo
    echo "KEEP_UP=1 — leaving postgres/redis/nats running."
    echo "Tear down later with:  docker compose -f $COMPOSE_FILE down"
    return
  fi
  echo
  echo "── Tearing down infra ──────────────────────────────────────────────"
  docker compose -f "$COMPOSE_FILE" down --remove-orphans
}
trap teardown EXIT

# ── Bring up infra ──────────────────────────────────────────────────────────
echo "── Bringing up infra: ${INFRA_SERVICES[*]} ────────────────────────────"
docker compose -f "$COMPOSE_FILE" up -d --wait "${INFRA_SERVICES[@]}" || {
  echo "ERROR: failed to bring up infra services" >&2
  exit 3
}

# Confirm host-side ports actually answer before we start a slow test loop.
echo
echo "── Confirming host-side connectivity ──────────────────────────────────"
wait_for_port() {
  local name="$1" host="$2" port="$3" tries=30
  while [ $tries -gt 0 ]; do
    if (echo > "/dev/tcp/$host/$port") >/dev/null 2>&1; then
      echo "  ✔ $name on $host:$port reachable"
      return 0
    fi
    sleep 1; tries=$((tries - 1))
  done
  echo "  ✘ $name on $host:$port NOT reachable" >&2
  return 1
}
wait_for_port postgres localhost 5432 || exit 3
wait_for_port redis    localhost 6379 || exit 3
wait_for_port nats     localhost 4222 || exit 3

# ── Run tests per service ───────────────────────────────────────────────────
# Use a TSV results file rather than associative arrays so this works on
# macOS's stock Bash 3.2 (no `declare -A`).
LOG_DIR="$(mktemp -d -t devopsagent-bal-test.XXXXXX)"
RESULTS_TSV="$LOG_DIR/results.tsv"
: > "$RESULTS_TSV"
echo
echo "── Running tests (logs: $LOG_DIR) ─────────────────────────────────────"

# Connection overrides — `bal test` runs in the host shell so service
# hostnames (postgres / redis / nats) won't resolve; redirect to localhost.
export DB_HOST=localhost
export REDIS_HOST=localhost
export NATS_URL=nats://localhost:4222

for svc in "${SERVICES[@]}"; do
  pkg_dir="generate/$svc"
  if [ ! -d "$pkg_dir" ]; then
    printf '%s\t%s\n' "$svc" "MISSING (no generate/$svc/)" >> "$RESULTS_TSV"
    continue
  fi
  log="$LOG_DIR/$svc.log"
  echo
  echo "── $svc ──────────────────────────────────────────────────────────"
  ( cd "$pkg_dir" && "$BAL" test ) > "$log" 2>&1
  rc=$?
  if [ $rc -eq 0 ]; then
    # Parse the bal-test summary footer for [N passing, N failing, N skipped].
    summary=$(grep -E '^[[:space:]]*[0-9]+ passing' "$log" | tail -1 | tr -s ' ' || true)
    if [ -n "$summary" ]; then
      status="PASS ($summary)"
    else
      status="PASS"
    fi
  else
    if grep -q 'compilation contains errors' "$log"; then
      status="COMPILE FAIL (rc=$rc)"
    elif grep -q 'Failed to initialize' "$log"; then
      status="INFRA INIT FAIL (rc=$rc)"
    else
      status="FAIL (rc=$rc)"
    fi
  fi
  printf '%s\t%s\n' "$svc" "$status" >> "$RESULTS_TSV"
  echo "  → $status"
done

# ── Summary table ───────────────────────────────────────────────────────────
echo
echo "════════════════════════════════════════════════════════════════════════"
echo " Results"
echo "════════════════════════════════════════════════════════════════════════"
printf '%-16s  %s\n' "SERVICE" "RESULT"
printf '%-16s  %s\n' "---------------" "----------------------------------------"
overall=0
failed_svcs=""
while IFS=$'\t' read -r svc status; do
  printf '%-16s  %s\n' "$svc" "$status"
  case "$status" in
    PASS*) ;;
    *) overall=1; failed_svcs="$failed_svcs $svc" ;;
  esac
done < "$RESULTS_TSV"
echo
echo "Per-service logs: $LOG_DIR"

# Print the tail of every failed log so the user doesn't have to dig.
if [ -n "$failed_svcs" ]; then
  for svc in $failed_svcs; do
    log="$LOG_DIR/$svc.log"
    [ -f "$log" ] || continue
    echo
    echo "────────────────────── FAIL: $svc — last 30 lines ──────────────────────"
    tail -n 30 "$log"
  done
fi

echo
if [ $overall -eq 0 ]; then
  echo "All services PASSED."
else
  echo "Some services failed — full logs under $LOG_DIR/"
fi
exit $overall
