#!/bin/bash
# Anthropic/Haiku A/B: 3 datasets x 6 per stack, sequential. LangChain is
# expected UP on anthropic; Ballerina is brought up after (reads anthropic .env).
set -u
source .env
CSV="$SP/ab_cloud.csv"; BODIES="$SP/bodies"; MEAS="$SP/measure_cloud.sh"

echo "########## LANGCHAIN (Haiku) datasets 1-3 ##########"
for ds in 1 2 3; do echo ">>> LangChain ds$ds"; bash "$MEAS" "LangChain" 18092 19196 6 "$CSV" "$BODIES" "$ds"; done

echo "########## SWITCH TO BALLERINA ##########"
( cd "$ROOT/LangChain Approach" && make demo-down ) >/dev/null 2>&1
( cd "$ROOT/MCP Best Practices Approach" && make demo-mock-up ) >/dev/null 2>&1
echo ">>> waiting for Ballerina agent + proxy + mocks"
n=0; until curl -s -o /dev/null -m 3 http://localhost:8092/health 2>/dev/null; do sleep 5; n=$((n+1)); [ $n -ge 150 ] && { echo "!! Ballerina never came up"; exit 1; }; done
until curl -s -o /dev/null -m 3 http://localhost:8290/health 2>/dev/null \
   && curl -s -o /dev/null -m 3 http://localhost:8400/health 2>/dev/null \
   && curl -s -o /dev/null -m 3 http://localhost:8401/health 2>/dev/null; do sleep 3; done
sleep 6

echo "########## BALLERINA (Haiku) datasets 1-3 ##########"
for ds in 1 2 3; do echo ">>> Ballerina ds$ds"; bash "$MEAS" "Ballerina" 8092 9196 6 "$CSV" "$BODIES" "$ds"; done

echo "########## CLOUD A/B DONE ##########"
