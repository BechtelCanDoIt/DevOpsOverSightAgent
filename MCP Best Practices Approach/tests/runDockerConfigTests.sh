#!/usr/bin/env bash
# test-docker-configuration.sh — creds-free integration test for the MCP Proxy
# federation layer + the agent's LLM-free skill endpoints.
#
# Validates 11 base assertions (Tests 1-11) WITHOUT an LLM or SaaS credentials
# — see the numbered `info`/`pass` lines below for the full list, spanning:
# lazy-loading tools/list, discover_tools + routing for splunk/datadog/apim/mi,
# local runbook dispatch, Phase 7's suggest_runbooks/health_report/top_issues,
# and Phase 4 §4.9's agent /top5 endpoint (proves it works with no LLM creds
# configured, since it bypasses the tool-use loop entirely). An opt-in
# `--with-infra` flag adds Tests 8i/8i-b for the Kubernetes MCP backend.
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
WITH_INFRA=false
PASS=0
FAIL=0

for arg in "$@"; do
  case "$arg" in
    --teardown) TEARDOWN=true ;;
    --no-start) NO_START=true ;;
    --no-build) NO_BUILD=true ;;
    --with-infra) WITH_INFRA=true ;;
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

# ── --with-infra: federate the Kubernetes MCP backend too ────────────────────
# Requires a container-reachable kubeconfig already prepared via
# `make infra-up` (or `./scripts/prepare-kubeconfig.sh`). If it's missing, we
# skip the k8s-specific tests with a clear message rather than failing the
# whole suite — infra-mcp is optional infrastructure, not part of the default
# creds-free demo path.
INFRA_READY=false
if [ "$WITH_INFRA" = true ]; then
  if [ -f "compose/kubeconfig/config" ]; then
    INFRA_READY=true
    export K8S_MCP_URL="http://k8s-mcp:8405"
  else
    echo "  ${YELLOW}SKIP${NC}  --with-infra given but compose/kubeconfig/config is missing."
    echo "         Run 'make infra-up' (or ./scripts/prepare-kubeconfig.sh) first."
  fi
fi

# ── Start services ────────────────────────────────────────────────────────────
if [ "$NO_START" = false ]; then
  if [ "$NO_BUILD" = false ]; then
    info "Building mcp-proxy + mock MCP server + agent images from current source..."
    docker compose -f "$COMPOSE_FILE" build splunk-mock-mcp datadog-mock-mcp apim-mcp mi-mcp is-mcp mcp-proxy devops-oversight-agent
    if [ "$INFRA_READY" = true ]; then
      docker compose -f "$COMPOSE_FILE" --profile infra-mcp build k8s-mcp
    fi
  fi
  info "Starting mcp-proxy + mock MCP servers (mesh not required)..."
  docker compose -f "$COMPOSE_FILE" up -d splunk-mock-mcp datadog-mock-mcp apim-mcp mi-mcp is-mcp mcp-proxy
  if [ "$INFRA_READY" = true ]; then
    info "Starting k8s-mcp (--profile infra-mcp)..."
    docker compose -f "$COMPOSE_FILE" --profile infra-mcp up -d k8s-mcp
    # mcp-proxy was already created above without K8S_MCP_URL — recreate it
    # now that the env var is exported and k8s-mcp is up.
    docker compose -f "$COMPOSE_FILE" up -d mcp-proxy
  fi
  info "Starting devops-oversight-agent (Phase 4 §4.9 skill endpoints)..."
  docker compose -f "$COMPOSE_FILE" up -d devops-oversight-agent
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
wait_health "http://localhost:8402/health" "apim-mcp :8402"
wait_health "http://localhost:8403/health" "mi-mcp :8403"
wait_health "http://localhost:8404/health" "is-mcp :8404"
if [ "$INFRA_READY" = true ]; then
  # k8s-mcp-server exposes /healthz, not /health — its own convention.
  wait_health "http://localhost:8405/healthz" "k8s-mcp :8405"
fi
wait_health "$PROXY_URL/health"            "mcp-proxy :8290"
wait_health "http://localhost:8092/health" "devops-oversight-agent :8092"

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

# ── Test 1b (R4): /health reports per-backend connection status ──────────────
info "Test 1b  GET /health includes backends.splunk=true and backends.datadog=true"
HEALTH_RESP=$(curl -sf "$PROXY_URL/health")
SPLUNK_UP=$(echo "$HEALTH_RESP" | jq -r '.backends.splunk // false')
DATADOG_UP=$(echo "$HEALTH_RESP" | jq -r '.backends.datadog // false')
if [ "$SPLUNK_UP" = "true" ] && [ "$DATADOG_UP" = "true" ]; then
  pass "/health: backends.splunk=true backends.datadog=true"
else
  fail "/health: expected both connected. Got: $HEALTH_RESP"
fi

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

# ── Test 5 (Phase 6): lazy loading holds for the new WSO2 backends too ────────
info "Test 5  tools/list: apim__/mi__/is__ stay hidden (lazy loading, same as splunk__/datadog__)"
LIST_RESP2=$(mcp_tools_list)
TOOL_NAMES2=$(echo "$LIST_RESP2" | jq -r '.result.tools[].name' 2>/dev/null || true)
HAS_APIM=$( echo "$TOOL_NAMES2" | grep -c "^apim__"  || true)
HAS_MI=$(   echo "$TOOL_NAMES2" | grep -c "^mi__"    || true)
HAS_IS=$(   echo "$TOOL_NAMES2" | grep -c "^is__"    || true)
if [ "$HAS_APIM" -eq 0 ] && [ "$HAS_MI" -eq 0 ] && [ "$HAS_IS" -eq 0 ]; then
  pass "tools/list: apim__/mi__/is__ absent (lazy loading preserved)"
else
  fail "tools/list: expected apim__/mi__/is__ hidden. apim=${HAS_APIM} mi=${HAS_MI} is=${HAS_IS}"
fi

# ── Test 6 (Phase 6): discover_tools surfaces the APIM manifest bundle ────────
info "Test 6  discover_tools('APIM api list') → JSON bundle with apim__apim_list_apis"
APIM_DISC_RESP=$(mcp_call_tool "discover_tools" '{"query":"APIM api list"}')
APIM_DISC_TEXT=$(echo "$APIM_DISC_RESP" | jq -r '.result.content[0].text' 2>/dev/null || true)
if echo "$APIM_DISC_TEXT" | jq -e '.tools[] | select(.name == "apim__apim_list_apis")' >/dev/null 2>&1; then
  pass "discover_tools: apim__apim_list_apis present in manifest bundle"
else
  fail "discover_tools: expected apim__apim_list_apis. Got: $APIM_DISC_TEXT"
fi

# ── Test 7 (Phase 6): mi__mi_get_message_processors routes to the MI mock ────
info "Test 7  mi__mi_get_message_processors routes to mock and shows the INACTIVE processor"
MI_RESP=$(mcp_call_tool "mi__mi_get_message_processors" '{}')
MI_TEXT=$(echo "$MI_RESP" | jq -r '.result.content[0].text' 2>/dev/null || true)
if echo "$MI_TEXT" | jq -e '.[] | select(.state == "INACTIVE" and .messageCount > 0)' >/dev/null 2>&1; then
  pass "mi__mi_get_message_processors: routed to mock, INACTIVE processor with queued messages present"
else
  fail "mi__mi_get_message_processors: expected an INACTIVE processor with messageCount>0. Got: $MI_TEXT"
fi

# ── Test 8 (Phase 7.1): topology__suggest_runbooks ranks disable-chaos first ──
info "Test 8  topology__suggest_runbooks ranks disable-chaos first for a chaos/502 diagnosis"
SUGGEST_RESP=$(mcp_call_tool "topology__suggest_runbooks" '{"service":"payment-service","diagnosis":"502 errors chaos injected"}')
SUGGEST_TEXT=$(echo "$SUGGEST_RESP" | jq -r '.result.content[0].text' 2>/dev/null || true)
FIRST_ID=$(echo "$SUGGEST_TEXT" | jq -r '.suggestions[0].id' 2>/dev/null || true)
if [ "$FIRST_ID" = "disable-chaos" ]; then
  pass "topology__suggest_runbooks: first suggestion is disable-chaos"
else
  fail "topology__suggest_runbooks: expected first suggestion disable-chaos, got '${FIRST_ID}'. Full: $SUGGEST_TEXT"
fi

# ── Test 9 (Phase 7.3): topology__health_report aggregates across backends ───
info "Test 9  topology__health_report → overall present, mesh section present"
HEALTH_RESP=$(mcp_call_tool "topology__health_report" '{}')
HEALTH_TEXT=$(echo "$HEALTH_RESP" | jq -r '.result.content[0].text' 2>/dev/null || true)
OVERALL=$(echo "$HEALTH_TEXT" | jq -r '.overall' 2>/dev/null || true)
SECTION_COUNT=$(echo "$HEALTH_TEXT" | jq '.sections | length' 2>/dev/null || echo 0)
if [ -n "$OVERALL" ] && [ "$OVERALL" != "null" ] && [ "$SECTION_COUNT" -gt 0 ]; then
  pass "topology__health_report: overall=${OVERALL}, ${SECTION_COUNT} section(s)"
else
  fail "topology__health_report: expected non-null overall + sections. Got: $HEALTH_TEXT"
fi

# ── Test 10 (Phase 7.4): topology__top_issues respects count + item shape ────
info "Test 10  topology__top_issues {count:3} → ≤3 issues, each with source/severity/target"
ISSUES_RESP=$(mcp_call_tool "topology__top_issues" '{"count":3}')
ISSUES_TEXT=$(echo "$ISSUES_RESP" | jq -r '.result.content[0].text' 2>/dev/null || true)
ISSUES_COUNT=$(echo "$ISSUES_TEXT" | jq '.issues | length' 2>/dev/null || echo -1)
SHAPE_OK=$(echo "$ISSUES_TEXT" | jq -e '.issues | all(has("source") and has("severity") and has("target"))' >/dev/null 2>&1 && echo true || echo false)
if [ "$ISSUES_COUNT" -ge 0 ] && [ "$ISSUES_COUNT" -le 3 ] && [ "$SHAPE_OK" = true ]; then
  pass "topology__top_issues: ${ISSUES_COUNT} issue(s), shape OK"
else
  fail "topology__top_issues: expected ≤3 well-shaped issues. Got: $ISSUES_TEXT"
fi

# ── Test 11 (Phase 4 §4.9): agent /top5 skill endpoint, no LLM loop needed ────
info "Test 11  GET :8092/top5?count=3 returns issues without going through the LLM loop"
TOP5_RESP=$(curl -sf "http://localhost:8092/top5?count=3" || true)
if echo "$TOP5_RESP" | jq -e '.issues' >/dev/null 2>&1; then
  TOP5_COUNT=$(echo "$TOP5_RESP" | jq '.issues | length')
  pass "GET /top5: returned ${TOP5_COUNT} issue(s)"
else
  fail "GET /top5: expected an issues field. Got: $TOP5_RESP"
fi

# ── Test 12 (Phase 6): INCLUDE_WSO2_MCP=N drops the WSO2 group from federation ─
# Recreates the proxy with the toggle off, asserts apim/mi/is disappear from
# both /health and discover_tools, then restores the default (Y) so the stack
# is left as the rest of the suite expects.
info "Test 12  INCLUDE_WSO2_MCP=N excludes apim/mi/is; restore leaves them federated"
INCLUDE_WSO2_MCP=N docker compose -f "$COMPOSE_FILE" up -d --force-recreate mcp-proxy >/dev/null 2>&1
# wait for proxy health + federation re-run (tools/list triggers ensureFederation)
for _ in $(seq 1 30); do curl -sf "$PROXY_URL/health" >/dev/null 2>&1 && break; sleep 1; done
mcp_tools_list >/dev/null 2>&1 || true   # triggers ensureFederation()
HEALTH_OFF=$(curl -sf "$PROXY_URL/health" 2>/dev/null || true)
APIM_OFF=$(echo "$HEALTH_OFF" | jq -r '.backends.apim // "absent"')
DISC_OFF=$(mcp_call_tool "discover_tools" '{"query":"APIM api list gateway"}' | jq -r '.result.content[0].text' 2>/dev/null || true)
DISC_HAS_APIM=$(echo "$DISC_OFF" | jq -e '.tools[]? | select(.name|startswith("apim__"))' >/dev/null 2>&1 && echo yes || echo no)
if [ "$APIM_OFF" = "absent" ] || [ "$APIM_OFF" = "false" ]; then
  if [ "$DISC_HAS_APIM" = "no" ]; then
    pass "INCLUDE_WSO2_MCP=N: apim/mi/is excluded from federation (not in /health, not discoverable)"
  else
    fail "INCLUDE_WSO2_MCP=N: apim__ tools still discoverable"
  fi
else
  fail "INCLUDE_WSO2_MCP=N: /health still lists apim backend (=${APIM_OFF})"
fi
# restore default so subsequent runs / leftover stack are back to Y
docker compose -f "$COMPOSE_FILE" up -d --force-recreate mcp-proxy >/dev/null 2>&1
for _ in $(seq 1 30); do curl -sf "$PROXY_URL/health" >/dev/null 2>&1 && break; sleep 1; done

# ── Test 8i (Phase 6.4, opt-in --with-infra): Kubernetes MCP federation ───────
if [ "$INFRA_READY" = true ]; then
  info "Test 8i  discover_tools('kubernetes pods') → k8s__pods_list present"
  K8S_DISC_RESP=$(mcp_call_tool "discover_tools" '{"query":"kubernetes pods"}')
  K8S_DISC_TEXT=$(echo "$K8S_DISC_RESP" | jq -r '.result.content[0].text' 2>/dev/null || true)
  if echo "$K8S_DISC_TEXT" | jq -e '.tools[] | select(.name == "k8s__pods_list")' >/dev/null 2>&1; then
    pass "discover_tools: k8s__pods_list present in manifest bundle"
  else
    fail "discover_tools: expected k8s__pods_list. Got: $K8S_DISC_TEXT"
  fi

  info "Test 8i-b  tools/list still hides k8s__* (lazy loading holds for the new backend too)"
  LIST_RESP3=$(mcp_tools_list)
  HAS_K8S=$(echo "$LIST_RESP3" | jq -r '.result.tools[].name' 2>/dev/null | grep -c "^k8s__" || true)
  if [ "$HAS_K8S" -eq 0 ]; then
    pass "tools/list: k8s__* absent (lazy loading preserved)"
  else
    fail "tools/list: expected k8s__* hidden, found $HAS_K8S"
  fi
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
  docker compose -f "$COMPOSE_FILE" stop mcp-proxy splunk-mock-mcp datadog-mock-mcp apim-mcp mi-mcp is-mcp devops-oversight-agent
  if [ "$INFRA_READY" = true ]; then
    docker compose -f "$COMPOSE_FILE" --profile infra-mcp stop k8s-mcp
  fi
fi

[ "$FAIL" -eq 0 ]
