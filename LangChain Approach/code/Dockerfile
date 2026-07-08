# syntax=docker/dockerfile:1
# One parameterized Dockerfile for every workspace member (mesh services,
# mock MCP servers, agents). Build context = code/ so the whole uv workspace
# (root pyproject + uv.lock + all members) is available to `uv sync`.
#
#   build:
#     context: ../code
#     args: { PACKAGE: payment-service, MODULE: payment_service.app }
#
# The venv is baked into the image and nothing volume-mounts over it — the
# Ballerina stack's stale-jar VOLUME bug is structurally impossible here.

FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim AS build
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy
WORKDIR /app
COPY . .
ARG PACKAGE
# Shared, lock-serialized uv download cache:
#  - target=/root/.cache/uv     → all images (and future rebuilds) reuse wheels
#  - sharing=locked             → the 14 parallel builds take TURNS at `uv sync`
#    instead of stampeding PyPI at once. The first does the cold download; the
#    rest hit a warm cache. This also fixes the DNS-under-load build failures.
RUN --mount=type=cache,target=/root/.cache/uv,sharing=locked \
    uv sync --frozen --no-dev --package "${PACKAGE}"

FROM python:3.12-slim
WORKDIR /app
# Create the runtime user BEFORE copying so ownership is assigned in a single
# pass. The old `chown -R /app` walked the whole venv (~58s/image) and, worse,
# duplicated every file into a new layer. `COPY --chown` bakes ownership into
# the copy layer itself — no walk, no duplicate layer.
RUN useradd --create-home appuser
COPY --from=build --chown=appuser:appuser /app /app
ARG MODULE
ENV APP_MODULE=${MODULE} \
    PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1
USER appuser
CMD ["/bin/sh", "-c", "python -m ${APP_MODULE}"]
