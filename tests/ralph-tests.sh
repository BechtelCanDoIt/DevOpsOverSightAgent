#!/usr/bin/env bash
# ralph-tests.sh — iterative test/fix loop using the `claude` CLI (Claude Code).
#
# Each iteration:
#   1. Run ./tests/runUnitTests.sh and capture the output (the script already auto-tails
#      every failed log).
#   2. If everything passes → exit 0.
#   3. Otherwise feed the failure output to Claude Code via `claude -p` with
#      file-edit permission, ask it to fix the bugs, and loop.
#
# Bail-out conditions:
#   - all tests pass (success)
#   - max iterations reached (failure)
#   - Claude Code made zero file changes since the previous iteration
#     (it's stuck — keep going burns API credits without progress)
#
# Requires: `claude` CLI on PATH, ANTHROPIC_API_KEY or a logged-in `claude` session,
# and ./tests/runUnitTests.sh from the same repo. Operates from the repo root.
#
# Usage:
#   ./tests/ralph-tests.sh                # up to 6 iterations
#   MAX_ITERATIONS=10 ./tests/ralph-tests.sh
#   MODEL=sonnet ./tests/ralph-tests.sh   # pass through to `claude --model`
#
# Logs of each iteration land under .ralph-logs/<timestamp>/ for after-the-fact
# review. Test infra teardown is handled by runUnitTests.sh's own EXIT trap.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MAX_ITERATIONS="${MAX_ITERATIONS:-6}"
MODEL="${MODEL:-}"   # leave empty to let `claude` pick its default
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR=".ralph-logs/$STAMP"
mkdir -p "$LOG_DIR"

# ── Preflight ───────────────────────────────────────────────────────────────
if ! command -v claude >/dev/null 2>&1; then
  echo "ERROR: 'claude' CLI not on PATH." >&2
  echo "       Install Claude Code (https://docs.claude.com/en/docs/claude-code)" >&2
  echo "       and run 'claude login' (or export ANTHROPIC_API_KEY) before retrying." >&2
  exit 2
fi
if [ ! -x ./tests/runUnitTests.sh ]; then
  echo "ERROR: ./tests/runUnitTests.sh not found or not executable." >&2
  exit 2
fi
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: not inside a git working tree." >&2
  echo "       ralph-tests.sh uses 'git diff' to detect whether Claude made progress;" >&2
  echo "       run 'git init' first if this is a fresh repo." >&2
  exit 2
fi

CLAUDE_FLAGS=(--dangerously-skip-permissions -p)
if [ -n "$MODEL" ]; then
  CLAUDE_FLAGS=(--model "$MODEL" "${CLAUDE_FLAGS[@]}")
fi

echo "════════════════════════════════════════════════════════════════════════"
echo " ralph-tests.sh — up to $MAX_ITERATIONS iterations"
echo " log dir: $LOG_DIR"
echo "════════════════════════════════════════════════════════════════════════"

# Track HEAD + worktree state at the start of each iteration. If Claude
# produces zero diff for an iteration, bail — it's stuck.
state_hash() {
  # SHA-1 of git's view of the worktree (tracked + untracked).
  {
    git status --porcelain
    git diff --no-color
    git diff --staged --no-color
  } 2>/dev/null | shasum | awk '{print $1}'
}

prev_state="$(state_hash)"

for i in $(seq 1 "$MAX_ITERATIONS"); do
  echo
  echo "════════════════════════════════════════════════════════════════════════"
  echo " Iteration $i / $MAX_ITERATIONS"
  echo "════════════════════════════════════════════════════════════════════════"

  RUN_LOG="$LOG_DIR/run-$i.log"

  # Run the test suite. Tee so the user sees live output too.
  ./tests/runUnitTests.sh 2>&1 | tee "$RUN_LOG"
  rc=${PIPESTATUS[0]}

  if [ "$rc" -eq 0 ]; then
    echo
    echo "✅ All tests passed on iteration $i."
    echo "   Logs: $LOG_DIR"
    exit 0
  fi

  if [ "$i" -eq "$MAX_ITERATIONS" ]; then
    echo
    echo "❌ Reached MAX_ITERATIONS=$MAX_ITERATIONS without all tests passing."
    echo "   Last run log: $RUN_LOG"
    echo "   All iteration logs: $LOG_DIR"
    exit 1
  fi

  echo
  echo "── Iteration $i failed. Handing the failure log to Claude Code ──"

  # Compose the prompt. runUnitTests.sh already prints the last 30 lines of each
  # failed service log at the end of its output, so $RUN_LOG is sufficient.
  PROMPT_FILE="$LOG_DIR/prompt-$i.md"
  cat > "$PROMPT_FILE" <<'PROMPT_HEADER'
You are inside the DevOpsOverSightAgent repo (see CLAUDE.md for project context). The
test runner `./tests/runUnitTests.sh` was just invoked and one or more Ballerina unit
test suites failed. The full output is below.

Your job: diagnose every failing service and fix the underlying bugs in the
service code or the test file — whichever is wrong. Do **not** re-run the
tests yourself; the outer loop will do that after you finish.

Hard constraints:
- Do NOT modify the seeded cross-cutting kit (`obs.bal`, `chaos.bal`,
  `tracing.bal`, `Config.toml`, `Ballerina.toml`, `Dockerfile`) unless a fix
  is impossible without it — and even then, the smallest possible change.
- Do NOT break any service that is currently passing in the report below.
- Do NOT delete tests, skip them, or weaken assertions to make them pass.
  Fix the underlying behavior or fix a genuinely wrong test expectation.
- Test files live at `generate/<svc>/tests/<svc>_test.bal`. Project
  conventions are in `generate/CONVENTIONS.md`.
- For Ballerina API patterns the seeded kit and the passing services
  (payment, inventory, notification, customer, store, invoice on the first
  green run) are reference implementations.

When you have applied your fixes, end with a one-paragraph summary of (a)
which file(s) you changed, and (b) the reasoning for each change. Then stop —
the outer loop will re-run the tests.

----- ./tests/runUnitTests.sh output -----
PROMPT_HEADER
  cat "$RUN_LOG" >> "$PROMPT_FILE"

  CLAUDE_LOG="$LOG_DIR/claude-$i.log"
  echo "    prompt: $PROMPT_FILE"
  echo "    claude output: $CLAUDE_LOG"
  echo
  claude "${CLAUDE_FLAGS[@]}" "$(cat "$PROMPT_FILE")" 2>&1 | tee "$CLAUDE_LOG"
  claude_rc=${PIPESTATUS[0]}
  if [ "$claude_rc" -ne 0 ]; then
    echo
    echo "WARNING: 'claude' exited with rc=$claude_rc — likely auth or quota."
    echo "         Aborting; review $CLAUDE_LOG for details."
    exit 3
  fi

  # Detect whether Claude actually changed anything since last iteration. If
  # not, it's stuck — keep looping just burns credits.
  new_state="$(state_hash)"
  if [ "$new_state" = "$prev_state" ]; then
    echo
    echo "❌ Claude made zero file changes this iteration — it's stuck."
    echo "   Last run log: $RUN_LOG"
    echo "   Claude output: $CLAUDE_LOG"
    exit 4
  fi
  prev_state="$new_state"

  echo
  echo "── Iteration $i fix attempt complete — re-running tests ──"
done
