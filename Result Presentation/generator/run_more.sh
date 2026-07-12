#!/bin/bash
# Run datasets 2 & 3 for both stacks, sequentially, one stack fully before the
# next. Ballerina is expected UP at start; LangChain is brought up after.
set -u
SP="$SP"
ROOT="$ROOT"
CSV="$SP/ab_multi.csv"; BODIES="$SP/bodies"; MEAS="$SP/measure.sh"

warm() { curl -s -m 120 http://localhost:11434/api/chat -d '{"model":"qwen2.5:14b-instruct","messages":[{"role":"user","content":"ready"}],"stream":false}' >/dev/null 2>&1; }

echo "########## BALLERINA datasets 2 & 3 ##########"
warm
echo ">>> Ballerina dataset 2"; bash "$MEAS" "Ballerina" 8092 9196 6 "$CSV" "$BODIES" 2
echo ">>> Ballerina dataset 3"; bash "$MEAS" "Ballerina" 8092 9196 6 "$CSV" "$BODIES" 3

echo "########## SWITCH STACKS ##########"
echo ">>> tearing down Ballerina"; ( cd "$ROOT/MCP Best Practices Approach" && make demo-down ) >/dev/null 2>&1
echo ">>> bringing up LangChain"; ( cd "$ROOT/LangChain Approach" && make demo-up ) >/dev/null 2>&1
echo ">>> waiting for LangChain orchestrator + specialists"
n=0; until curl -s -o /dev/null -m 3 http://localhost:18092/health 2>/dev/null; do sleep 5; n=$((n+1)); [ $n -ge 120 ] && { echo "!! LangChain orchestrator never came up"; exit 1; }; done
until curl -s -o /dev/null -m 3 http://localhost:18101/.well-known/agent-card.json 2>/dev/null \
   && curl -s -o /dev/null -m 3 http://localhost:18102/.well-known/agent-card.json 2>/dev/null; do sleep 3; done
sleep 6; warm

echo "########## LANGCHAIN datasets 2 & 3 ##########"
echo ">>> LangChain dataset 2"; bash "$MEAS" "LangChain" 18092 19196 6 "$CSV" "$BODIES" 2
echo ">>> LangChain dataset 3"; bash "$MEAS" "LangChain" 18092 19196 6 "$CSV" "$BODIES" 3

echo "########## ALL DATASETS DONE ##########"
