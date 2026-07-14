#!/usr/bin/env bash
# prepare-kubeconfig.sh — produce a container-reachable kubeconfig for the
# k8s-mcp-server compose service (Phase 6.4, --profile infra-mcp).
#
# Why this exists: your current kubectl context almost always points its API
# server at 127.0.0.1 (Rancher Desktop, kind, k3d-on-Docker-Desktop all do
# this) — that's fine from your shell, but unreachable from INSIDE another
# container, since 127.0.0.1 there means "this container," not "your Mac."
# We flatten+minify the current context and rewrite the host to
# host.docker.internal (which every container in this compose stack already
# resolves back to the Docker host — same trick used for OLLAMA_BASE_URL).
# The rewritten server almost certainly presents a certificate that doesn't
# have host.docker.internal in its SAN list, so we also drop the embedded CA
# and skip TLS verification — acceptable for a local, single-developer demo
# cluster; do not do this for anything you don't control.
#
# Usage:
#   ./scripts/prepare-kubeconfig.sh             # uses your current context
#   ./scripts/prepare-kubeconfig.sh my-context   # uses a specific context

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$REPO_ROOT/compose/kubeconfig"
OUT_FILE="$OUT_DIR/config"
CONTEXT="${1:-}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl not found on PATH." >&2
  exit 2
fi

mkdir -p "$OUT_DIR"

if [ -n "$CONTEXT" ]; then
  kubectl config view --raw --minify --flatten --context="$CONTEXT" > "$OUT_FILE"
else
  CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
  if [ -z "$CONTEXT" ]; then
    echo "ERROR: no current kubectl context set, and none given as an argument." >&2
    echo "       Run 'kubectl config get-contexts' and pass one explicitly." >&2
    exit 2
  fi
  kubectl config view --raw --minify --flatten > "$OUT_FILE"
fi

echo "Using context: $CONTEXT"

# Rewrite a 127.0.0.1/localhost API server to host.docker.internal, drop the
# embedded CA data (the cert won't validate against the new hostname anyway),
# and set insecure-skip-tls-verify so the container can still connect over TLS.
python3 - "$OUT_FILE" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path) as f:
    content = f.read()

content = re.sub(
    r"(server:\s*https://)(127\.0\.0\.1|localhost)(:\d+)",
    r"\1host.docker.internal\3",
    content,
)
# Drop the embedded CA data line(s) — the rewritten host won't be in the SAN list.
content = "\n".join(
    line for line in content.splitlines() if "certificate-authority-data:" not in line
)
# Add insecure-skip-tls-verify right after the (now CA-less) server: line.
lines = content.splitlines()
out = []
for line in lines:
    out.append(line)
    if re.match(r"\s*server:\s*https://host\.docker\.internal:\d+", line):
        indent = line[: len(line) - len(line.lstrip())]
        out.append(indent + "insecure-skip-tls-verify: true")
with open(path, "w") as f:
    f.write("\n".join(out) + "\n")
PY

chmod 600 "$OUT_FILE"
echo "Prepared $OUT_FILE"
echo ""
echo "Next: docker compose -f compose/docker-compose.yml --profile infra-mcp up -d k8s-mcp"
echo "      (or: make infra-up)"
