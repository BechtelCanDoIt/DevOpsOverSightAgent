#!/bin/bash
# Fair A/B harness. Injects the same payment-service chaos, times /investigate
# (time-to-proposal), counts LLM calls via the Ollama access log, saves the full
# response body per run, and checks the proposal is correct.
# Runs one warm-up (discarded) + N measured runs. No concurrent monitoring.
#
# Usage: measure.sh <NAME> <AGENT_PORT> <CHAOS_PORT> <N> <OUTCSV> <BODYDIR>
set -u
NAME="$1"; AGENT="$2"; CHAOS="$3"; N="${4:-6}"; OUT="$5"; BODYDIR="$6"; DS="${7:-1}"
TOKEN="dev-chaos-token"
OLOG="$HOME/.ollama/logs/server.log"
PAYLOAD='{"service":"payment-service","severity":"P1","description":"502 spike detected","id":"INC-AB-1"}'
mkdir -p "$BODYDIR"

chat_count() { grep -c '/api/chat' "$OLOG" 2>/dev/null || echo 0; }
inject() {
  curl -s -m 15 -o /dev/null -X POST "http://localhost:$CHAOS/chaos/error" \
    -H "X-Chaos-Token: $TOKEN" -H 'Content-Type: application/json' -d '{"rate":0.8,"status":502,"duration_s":240}'
  curl -s -m 15 -o /dev/null -X POST "http://localhost:$CHAOS/chaos/latency" \
    -H "X-Chaos-Token: $TOKEN" -H 'Content-Type: application/json' -d '{"ms":2000,"duration_s":240}'
}
reset() { curl -s -m 15 -o /dev/null -X POST "http://localhost:$CHAOS/chaos/reset" -H "X-Chaos-Token: $TOKEN"; }

run_once() {
  local rid="$1" c0 c1 body lat code valid dd sp bf
  reset; sleep 2; inject; sleep 4
  c0=$(chat_count)
  bf="$BODYDIR/${NAME}_ds${DS}_run${rid}.txt"
  resp=$(curl -s -m 600 -w '\n%{http_code} %{time_total}' -X POST \
    "http://localhost:$AGENT/investigate" -H 'Content-Type: application/json' -d "$PAYLOAD")
  c1=$(chat_count)
  local trailer body
  trailer=$(printf '%s' "$resp" | tail -1)
  body=$(printf '%s' "$resp" | sed '$d')
  printf '%s' "$body" > "$bf"
  code=$(echo "$trailer" | awk '{print $1}')
  lat=$(echo "$trailer" | awk '{print $2}')
  local calls=$((c1 - c0))
  if echo "$body" | grep -qi 'disable-chaos' && echo "$body" | grep -qi 'payment-service'; then valid=1; else valid=0; fi
  dd=0; sp=0
  echo "$body" | grep -qi 'datadog\|monitor\|error.rate\|metric\|trace' && dd=1
  echo "$body" | grep -qi 'splunk\|log\|SPL\|502' && sp=1
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$NAME" "$DS" "$rid" "$lat" "$calls" "$code" "$valid" "$((dd+sp))" >> "$OUT"
  echo "  ds$DS run $rid: ${lat}s  llm_calls=$calls  http=$code  valid=$valid  platforms=$((dd+sp))/2"
  reset; sleep 3
}

echo "== $NAME :: warm-up (discarded) =="
run_once "warmup"
echo "== $NAME :: $N measured runs =="
for i in $(seq 1 "$N"); do run_once "$i"; done
echo "== $NAME :: DONE =="
