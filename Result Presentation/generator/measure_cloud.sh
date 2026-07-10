#!/bin/bash
# Cloud (Anthropic) A/B harness: same as measure.sh but no Ollama-log call count
# (LLM calls happen at api.anthropic.com). Measures time-to-proposal + validity.
# Usage: measure_cloud.sh <NAME> <AGENT_PORT> <CHAOS_PORT> <N> <OUTCSV> <BODYDIR> <DATASET>
set -u
NAME="$1"; AGENT="$2"; CHAOS="$3"; N="${4:-6}"; OUT="$5"; BODYDIR="$6"; DS="${7:-1}"
TOKEN="dev-chaos-token"
PAYLOAD='{"service":"payment-service","severity":"P1","description":"502 spike detected","id":"INC-AB-1"}'
mkdir -p "$BODYDIR"

inject() {
  curl -s -m 15 -o /dev/null -X POST "http://localhost:$CHAOS/chaos/error" \
    -H "X-Chaos-Token: $TOKEN" -H 'Content-Type: application/json' -d '{"rate":0.8,"status":502,"duration_s":240}'
  curl -s -m 15 -o /dev/null -X POST "http://localhost:$CHAOS/chaos/latency" \
    -H "X-Chaos-Token: $TOKEN" -H 'Content-Type: application/json' -d '{"ms":2000,"duration_s":240}'
}
reset() { curl -s -m 15 -o /dev/null -X POST "http://localhost:$CHAOS/chaos/reset" -H "X-Chaos-Token: $TOKEN"; }

run_once() {
  local rid="$1" body lat code valid dd sp bf trailer resp
  reset; sleep 2; inject; sleep 4
  bf="$BODYDIR/${NAME}_cloud_ds${DS}_run${rid}.txt"
  resp=$(curl -s -m 300 -w '\n%{http_code} %{time_total}' -X POST \
    "http://localhost:$AGENT/investigate" -H 'Content-Type: application/json' -d "$PAYLOAD")
  trailer=$(printf '%s' "$resp" | tail -1)
  body=$(printf '%s' "$resp" | sed '$d')
  printf '%s' "$body" > "$bf"
  code=$(echo "$trailer" | awk '{print $1}')
  lat=$(echo "$trailer" | awk '{print $2}')
  if echo "$body" | grep -qi 'disable-chaos' && echo "$body" | grep -qi 'payment-service'; then valid=1; else valid=0; fi
  dd=0; sp=0
  echo "$body" | grep -qi 'datadog\|monitor\|error.rate\|metric\|trace' && dd=1
  echo "$body" | grep -qi 'splunk\|log\|SPL\|502' && sp=1
  printf '%s,%s,%s,%s,-,%s,%s,%s\n' "$NAME" "$DS" "$rid" "$lat" "$code" "$valid" "$((dd+sp))" >> "$OUT"
  echo "  ds$DS run $rid: ${lat}s  http=$code  valid=$valid  platforms=$((dd+sp))/2"
  reset; sleep 2
}

echo "== $NAME (cloud) :: warm-up (discarded) =="
run_once "warmup"
echo "== $NAME (cloud) :: $N measured runs =="
for i in $(seq 1 "$N"); do run_once "$i"; done
echo "== $NAME (cloud) :: DONE =="
