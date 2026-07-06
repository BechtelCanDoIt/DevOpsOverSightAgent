#!/usr/bin/env bash
# test-docker-configuration.sh — creds-free integration test for the MCP Proxy federation layer.
#
# Validates four invariants WITHOUT an LLM or SaaS credentials:
#   1. tools/list returns discover_tools + topology__ tools ONLY (lazy loading holds)
#   2. discover_tools(query) returns a JSON manifest bundle with splunk__splunk_run_query
#   3. splunk__splunk_run_query routes through the proxy to the Splunk mock and
#      returns fixture data (result_count is present in the response)
#   4. topology__list_runbooks dispatches locally and returns the runbook catalog
#      (disable-chaos present)
#
# Usage:
#   ./tests/runDockerConfigTests.sh              # build images, start services, run tests, leave them up
#   ./tests/runDockerConfigTests.sh --teardown   # tear services down after tests finish
#   ./tests/runDockerConfigTests.sh --no-build   # skip image rebuild (use cached images)
#   ./tests/runDockerConfigTests.sh --no-start   # skip 'docker compose up' (services already running)
#
# Requires: docker, docker compose, curl, jq

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

COMPOSE_FILE="compose/docker-compose.yml"
PROXY_URL="http://localhost:8290"
TEARDOWN=false
NO_START=false
NO_BUILD=false
PASS=0
FAIL=0

for arg in "$@"; do
  case "$arg" in
    --teardown) TEARDOWN=true ;;
    --no-start) NO_START=true ;;
    --no-build) NO_BUILD=true ;;
  esac
done

# ── Terminal colour helpers ───────────────────────────────────────────────────
if [ -t 1 ]; then
  RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[1;33m' NC=$'\033[0m'
else
  RED='' GREEN='' YELLOW='' NC=''
fi

pass() { echo "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS + 1)); }
fail() { echo "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL + 1)); }
info() { echo "  ${YELLOW}....${NC}  $1"; }

echo "════════════════════════════════════════════════════════════════════════"
echo " MCP Proxy — federation integration test (creds-free)"
echo "════════════════════════════════════════════════════════════════════════"

# ── Preflight ────────────────────────────────────────────────────────────────
for cmd in docker curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: '$cmd' is required but not on PATH." >&2; exit 2
  fi
done

# ── Start services ────────────────────────────────────────────────────────────
if [ "$NO_START" = false ]; then
  if [ "$NO_BUILD" = false ]; then
    info "Building mcp-proxy + mock MCP server images from current source..."
    docker compose -f "$COMPOSE_FILE" build splunk-mock-mcp datadog-mock-mcp mcp-proxy
  fi
  info "Starting mcp-proxy + mock MCP servers (mesh not required)..."
  docker compose -f "$COMPOSE_FILE" up -d splunk-mock-mcp datadog-mock-mcp mcp-proxy
fi

# ── Wait for health ───────────────────────────────────────────────────────────
wait_health() {
  local url="$1" label="$2" tries=0
  info "Waiting for $label to be healthy..."
  while ! curl -sf "$url" >/dev/null 2>&1; do
    if [ $((tries += 1)) -ge 40 ]; then
      fail "$label did not become healthy within 40 s"
      exit 1
    fi
    sleep 1
  done
  info "$label is UP"
}

wait_health "http://localhost:8400/health" "splunk-mock-mcp :8400"
wait_health "http://localhost:8401/health" "datadog-mock-mcp :8401"
wait_health "$PROXY_URL/health"            "mcp-proxy :8290"

# ── MCP call helpers ──────────────────────────────────────────────────────────
# Sends a bare tools/list without a prior initialize — the proxy is stateless
# over HTTP so every request is independent; initialize is optional for tests.
mcp_tools_list() {
  curl -sf -X POST "$PROXY_URL/mcp" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
}

mcp_call_tool() {
  local name="$1" args="$2"
  curl -sf -X POST "$PROXY_URL/mcp" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"${name}\",\"arguments\":${args}}}"
}

echo
echo "── Assertions ──────────────────────────────────────────────────────────"

# ── Test 1: lazy loading — tools/list must NOT reveal splunk__/datadog__ ──────
info "Test 1  tools/list: discover_tools + topology__ only (splunk__/datadog__ hidden)"
LIST_RESP=$(mcp_tools_list)
if echo "$LIST_RESP" | jq -e '.result.tools' >/dev/null 2>&1; then
  TOOL_NAMES=$(echo "$LIST_RESP" | jq -r '.result.tools[].name')
  HAS_DISCOVER=$(echo "$TOOL_NAMES" | grep -c "^discover_tools$" || true)
  HAS_TOPOLOGY=$(echo "$TOOL_NAMES" | grep -c "^topology__"     || true)
  HAS_SPLUNK=$(  echo "$TOOL_NAMES" | grep -c "^splunk__"       || true)
  HAS_DATADOG=$( echo "$TOOL_NAMES" | grep -c "^datadog__"      || true)
  if [ "$HAS_DISCOVER" -ge 1 ] && [ "$HAS_TOPOLOGY" -ge 1 ] && \
     [ "$HAS_SPLUNK"   -eq 0 ] && [ "$HAS_DATADOG"  -eq 0 ]; then
    TOPO_COUNT=$(echo "$TOOL_NAMES" | grep -c "^topology__" || true)
    pass "tools/list: discover_tools + ${TOPO_COUNT} topology__ tools; splunk__/datadog__ absent"
  else
    fail "tools/list: unexpected tool set. discover=${HAS_DISCOVER} topology=${HAS_TOPOLOGY} splunk=${HAS_SPLUNK} datadog=${HAS_DATADOG}"
    echo "  tools returned: $(echo "$TOOL_NAMES" | tr '\n' ' ')"
  fi
else
  fail "tools/list: no result.tools in response: $LIST_RESP"
fi

# tools/list calls ensureFederation() — backends are now connected and their
# namespaced tools are in the registry. Subsequent tests can use them.

# ── Test 2: discover_tools returns splunk manifest bundle ─────────────────────
info "Test 2  discover_tools('Splunk log query') → JSON bundle with splunk__splunk_run_query"
DISC_RESP=$(mcp_call_tool "discover_tools" '{"query":"Splunk log query"}')
DISC_TEXT=$(echo "$DISC_RESP" | jq -r '.result.content[0].text' 2>/dev/null || true)
if echo "$DISC_TEXT" | jq -e '.tools' >/dev/null 2>&1 && \
   echo "$DISC_TEXT" | jq -e '.tools[] | select(.name == "splunk__splunk_run_query")' >/dev/null 2>&1; then
  MATCH_COUNT=$(echo "$DISC_TEXT" | jq '.tools | length')
  pass "discover_tools: returned manifest bundle (${MATCH_COUNT} tool(s)), splunk__splunk_run_query present"
else
  fail "discover_tools: expected JSON bundle with splunk__splunk_run_query. Got: $DISC_TEXT"
fi

# ── Test 3: splunk__splunk_run_query routes through the proxy ─────────────────
info "Test 3  splunk__splunk_run_query routes to Splunk mock and returns fixture data"
SPLUNK_RESP=$(mcp_call_tool "splunk__splunk_run_query" '{"query":"error status=502"}')
SPLUNK_TEXT=$(echo "$SPLUNK_RESP" | jq -r '.result.content[0].text' 2>/dev/null || true)
if echo "$SPLUNK_TEXT" | jq -e '.result_count' >/dev/null 2>&1; then
  RC=$(echo "$SPLUNK_TEXT" | jq '.result_count')
  pass "splunk__splunk_run_query: routed to mock, result_count=${RC}"
else
  # Check for an error response from the proxy itself
  ERR=$(echo "$SPLUNK_RESP" | jq -r '.error.message' 2>/dev/null || true)
  fail "splunk__splunk_run_query: no result_count in response. proxy_error=${ERR:-none} text=${SPLUNK_TEXT:-empty}"
fi

# ── Test 4: topology__list_runbooks dispatches locally ────────────────────────
info "Test 4  topology__list_runbooks dispatches locally (no backend needed)"
RB_RESP=$(mcp_call_tool "topology__list_runbooks" '{}')
RB_TEXT=$(echo "$RB_RESP" | jq -r '.result.content[0].text' 2>/dev/null || true)
if echo "$RB_TEXT" | jq -e '.[] | select(.id == "disable-chaos")' >/dev/null 2>&1; then
  RB_COUNT=$(echo "$RB_TEXT" | jq 'length')
  pass "topology__list_runbooks: local dispatch returned ${RB_COUNT} runbooks (disable-chaos present)"
else
  fail "topology__list_runbooks: expected local runbook catalog with disable-chaos. Got: $RB_TEXT"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "════════════════════════════════════════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then
  echo " ${GREEN}All ${PASS} tests passed.${NC}"
else
  echo " ${GREEN}${PASS} passed${NC}  ${RED}${FAIL} failed${NC}"
fi
echo "════════════════════════════════════════════════════════════════════════"

if [ "$TEARDOWN" = true ]; then
  info "Tearing down mcp-proxy + mock MCP servers..."
  docker compose -f "$COMPOSE_FILE" stop mcp-proxy splunk-mock-mcp datadog-mock-mcp
fi

[ "$FAIL" -eq 0 ]
