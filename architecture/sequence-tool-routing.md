# Sequence Diagram — Tool Routing Detail: discover_tools → Registry → MCP Dispatch

Paste the Mermaid block below into [mermaid.live](https://mermaid.live) or any compatible renderer.

```mermaid
sequenceDiagram
    autonumber
    participant LLM as LLM (Anthropic/Ollama)
    participant AgentLoop as Agent Tool AgentLoop<br/>(runConfiguredLlm)
    participant Dispatcher as makeDispatcher closure
    participant Registry as Tool Registry<br/>(name to AnthropicTool)
    participant SplunkMCP as Splunk Mock MCP<br/>:8400
    participant DatadogMCP as Datadog Mock MCP<br/>:8401
    participant TopologyMCP as MCP Proxy<br/>:8290

    Note over AgentLoop,Registry: Session start — initMcp() populates registry<br/>splunk__*(4) + datadog__*(8) + topology__*(11) = 23 tools<br/>activeTools = [discover_tools] + topology__*(11) only

    LLM->>AgentLoop: tool_use { name: "discover_tools",<br/>input: { query: "Splunk 502 errors logs" } }
    AgentLoop->>Dispatcher: dispatch("discover_tools", { query: … })

    Note over Dispatcher,Registry: searchRegistry(registry, query, maxResults=5)

    loop for each tool in registry (23 tools)
        Dispatcher->>Registry: scoreToolMatch(name, description, query)
        Note over Registry: tokenize query → score words:<br/>exact match in name+desc = +2<br/>4-char prefix (word ≥5 chars) = +1
        Registry-->>Dispatcher: score
    end

    Dispatcher->>Dispatcher: selection sort descending by score
    Dispatcher->>Dispatcher: top-5 tools: splunk__splunk_run_query (+6),<br/>splunk__splunk_get_indexes (+4), …

    loop for each matched tool
        Dispatcher->>AgentLoop: activeTools.push(tool schema)<br/>(skip if already present)
    end

    Dispatcher-->>AgentLoop: Loaded 4 tools — now callable: splunk__splunk_run_query …
    AgentLoop-->>LLM: tool_result { content: "Loaded 4 tool(s)…" }<br/>+ updated activeTools injected into next LLM call

    Note over LLM: LLM now sees splunk__* schemas in tools list

    LLM->>AgentLoop: tool_use { name: "splunk__splunk_run_query",<br/>input: { query: "error status=502", earliest: "-1h" } }
    AgentLoop->>Dispatcher: dispatch("splunk__splunk_run_query", { … })

    Note over Dispatcher: Route decision:<br/>strip "__" prefix → realName = "splunk_run_query"<br/>realName.startsWith("splunk_") → target = splunkMcp

    Dispatcher->>SplunkMCP: POST /mcp<br/>{ method: "tools/call",<br/>  params: { name: "splunk_run_query", arguments: {…} } }
    SplunkMCP-->>Dispatcher: { result: { content: [{ type:"text", text: "…" }] } }
    Dispatcher-->>AgentLoop: result.text (verbatim)
    AgentLoop-->>LLM: tool_result { content: "log events…" }

    Note over LLM: LLM reasons — calls discover_tools again for Datadog

    LLM->>AgentLoop: tool_use { name: "discover_tools",<br/>input: { query: "Datadog trace APM spans" } }
    AgentLoop->>Dispatcher: dispatch("discover_tools", { query: … })
    Dispatcher->>Registry: searchRegistry — scores datadog__*/apm_* higher
    Note over Registry: "datadog" exact match (+2), "trace" exact match (+2),<br/>"apm" exact match (+2) → datadog__get_datadog_trace scores highest
    Dispatcher-->>AgentLoop: activeTools.push(datadog__* schemas)
    AgentLoop-->>LLM: tool_result "Loaded 3 tool(s)…"

    LLM->>AgentLoop: tool_use { name: "datadog__get_datadog_trace",<br/>input: { trace_id: "abc123" } }
    AgentLoop->>Dispatcher: dispatch("datadog__get_datadog_trace", { … })

    Note over Dispatcher: realName = "get_datadog_trace"<br/>realName.includes("datadog") → target = datadogMcp

    Dispatcher->>DatadogMCP: POST /mcp<br/>{ method: "tools/call",<br/>  params: { name: "get_datadog_trace", arguments: {…} } }
    DatadogMCP-->>Dispatcher: trace spans JSON
    Dispatcher-->>AgentLoop: result.text
    AgentLoop-->>LLM: tool_result { content: "trace spans…" }

    Note over LLM: Topology tools already in activeTools — no discover_tools needed

    LLM->>AgentLoop: tool_use { name: "topology__correlate_trace",<br/>input: { trace_id: "abc123" } }
    AgentLoop->>Dispatcher: dispatch("topology__correlate_trace", { … })

    Note over Dispatcher: realName = "correlate_trace"<br/>not splunk_* / not datadog / not apm_* → target = topologyMcp

    Dispatcher->>TopologyMCP: POST /mcp<br/>{ method: "tools/call",<br/>  params: { name: "correlate_trace", arguments: {…} } }
    TopologyMCP-->>Dispatcher: { datadog_url, splunk_spl, involved_services }
    Dispatcher-->>AgentLoop: result.text
    AgentLoop-->>LLM: tool_result { content: "…" }
```

## Routing decision table

The dispatcher strips the `__` namespace prefix to get `realName`, then applies these rules in order:

| Condition on `realName` | Target client | Example tool |
|------------------------|---------------|--------------|
| `startsWith("splunk_")` | `splunkMcp :8400` | `splunk_run_query` |
| `includes("datadog")` OR `startsWith("apm_")` | `datadogMcp :8401` | `get_datadog_trace`, `apm_search_spans` |
| anything else | `topologyMcp :8290` | `correlate_trace`, `run_runbook` |

## Keyword scorer details

`scoreToolMatch(name, description, query)` concatenates `name + description`, lowercases both, then tokenizes the query:

- Words ≤ 2 chars: **skip** (stop words)
- Exact word present in haystack: **+2**
- Word ≥ 5 chars AND its 4-char prefix present: **+1** (handles plurals/stems, e.g. "errors" matches "error")

Tools with score = 0 are excluded. Top-5 by score are added to `activeTools`. This is an intentional choice over pgvector for ~21 tools in a POC — no embedding infrastructure required.
