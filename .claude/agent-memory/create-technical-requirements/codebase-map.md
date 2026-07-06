---
name: codebase-map
description: DevOps Observability POC component catalog, ports, source layout, and TRS output location
metadata:
  type: project
---

# DevOps Observability POC — component/port map

An AI agent correlates Splunk (logs/traces) + Datadog (APM/metrics) over MCP to diagnose and remediate incidents in a 7-service Ballerina retail mesh. Entire stack is Ballerina.

**TRS output:** `requirements/technical-requirements.md` (repo has `todo/` but NOT `requirements/`; per skill, since only `todo/` exists, rename it — BUT the user explicitly asked for `requirements/technical-requirements.md` as a NEW dir; created `requirements/` fresh, left `todo/` intact since it holds authoritative phase specs still referenced).

## Components + ports (host)
- devops-oversight-agent — container :8080 → host :8092 (host 8082 collides with Colima AMP VM). POST /investigate, /webhook/alert, /chat, GET /health
- mcp-proxy — :8290 Streamable HTTP at /mcp; owns topology/correlation/runbook tools, federates Splunk/DD
- splunk-mock-mcp — :8400
- datadog-mock-mcp — :8401
- 7 mesh services (code/generate/): store customer order inventory invoice payment notification + load-gen
- chaos ports published 9191–9197 (payment = host 9196), token X-Chaos-Token: dev-chaos-token
- OTel Collector OTLP :4317 gRPC / :4318 HTTP; postgres 5432; redis; nats; jaeger 16686 (dev-only)

## Source layout
- code/agent/ — llm_client.bal (4 providers: ollama default/anthropic/openai/amp), anthropic_client.bal, mcp_client.bal (JSON-RPC 2.0 /mcp), prompts.bal, devops_oversight_agent.bal
- code/mcp/mcp-proxy/ — mcp_server.bal, catalog.bal (static 7-service map), correlation.bal, federation.bal, runbooks.bal
- code/mcp/{splunk,datadog}-mock-mcp/
- code/generate/<svc>/ — service.bal + chaos.bal + obs.bal + tracing.bal; OTel name is <dir>-service
- compose/ — docker-compose.yml + docker-compose.saas.yml (--profile saas), otel-collector/config.yaml, postgres/init.sql, .env.example

## Test counts
129 total bal tests across 12 packages: mcp-proxy 22, splunk-mock 8, datadog-mock 11, agent 8, mesh services make up rest.

## Key docs
README.md (component catalog), architecture/architecture.md (deep dive), todo/phase-0..5, decisions.md, KNOWN_ISSUES.md, "mcp best practices/".
