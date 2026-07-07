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
RUN uv sync --frozen --no-dev --package "${PACKAGE}"

FROM python:3.12-slim
WORKDIR /app
COPY --from=build /app /app
ARG MODULE
ENV APP_MODULE=${MODULE} \
    PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1
RUN useradd --create-home appuser && chown -R appuser /app
USER appuser
CMD ["/bin/sh", "-c", "python -m ${APP_MODULE}"]
