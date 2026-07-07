# Phase 3 — Mock MCP Servers

**Goal:** spec-compliant FastMCP mocks of the Splunk and Datadog MCP servers,
tool-level faithful to the Ballerina mocks.

## Tasks

- [x] 3.1 `splunk_mock_mcp`: FastMCP streamable-http at `/mcp` on :8400, `/health`
      route, 4 tools (`splunk_run_query`, `splunk_get_indexes`,
      `splunk_get_knowledge_objects`, `splunk_describe_query`). Fixtures + the
      `filter_events` heuristic (trace-id 8-char prefix; 502/error → status>=400
      with empty-fallback) ported verbatim; demo trace id preserved.
- [x] 3.2 `datadog_mock_mcp`: FastMCP on :8401, `/health`, 8 tools
      (metrics/traces/spans/monitors/logs/error-tracking/dashboards). Fixtures +
      `lookup_metric` fuzzy fallback + `filter_monitors` ported verbatim.
- [x] 3.3 Tool names **unprefixed** (no proxy); result JSON matches the Ballerina
      shape (`json.dumps(...)` string content).
- [x] 3.4 Unit tests: exact result JSON per tool + registered-tool-count (4 / 8).

## Exit criteria

- [x] `uv run pytest mcp` green; both servers import and register exactly 4 / 8 tools.
- [x] (On a Docker host) an MCP client `tools/list` returns the tool sets and
      `splunk_run_query("payment 502")` returns the demo-trace events.
