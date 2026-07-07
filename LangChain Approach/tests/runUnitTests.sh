#!/usr/bin/env bash
# Run the full Python unit-test suite across the uv workspace.
#
# Infra-free by design: DB/Redis/NATS clients are lazy factories that tests
# monkeypatch, so no Postgres/Redis/NATS is needed (a deliberate improvement
# over the Ballerina stack's infra-up-first requirement). OTel export is
# disabled so nothing tries to reach a collector.
set -euo pipefail

cd "$(dirname "$0")/../code"

export OTEL_SDK_DISABLED=true
# Ensure the anthropic default provider readiness probe stays quiet in tests.
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"

echo "==> Running unit tests (uv run pytest)"
uv run pytest "$@"
