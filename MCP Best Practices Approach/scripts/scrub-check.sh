#!/usr/bin/env bash
# scrub-check.sh — naming regression guard.
#
# Hard requirement (see CLAUDE.md / todo/README.md "Locked decisions"): the
# Customer's real company name must NEVER appear in any git-tracked file —
# docs, code, config, comments. Always "Customer" in generic text; anything
# environment-specific must come from a .env file (untracked), never a
# hardcoded literal.
#
# Scans every git-tracked file (git ls-files already excludes .git/ and
# anything gitignored, e.g. target/ build output) for a case-insensitive
# match against the forbidden name. Zero matches = pass.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FORBIDDEN="fidelity"

MATCHES=$(git ls-files -z | xargs -0 grep -liE "$FORBIDDEN" 2>/dev/null || true)

if [ -z "$MATCHES" ]; then
  echo "scrub-check: PASS — no occurrences of the forbidden name in tracked files."
  exit 0
else
  echo "scrub-check: FAIL — forbidden name found in:"
  echo "$MATCHES" | sed 's/^/  /'
  exit 1
fi
