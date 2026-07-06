# Sequence Diagram — Overview: Agent → MCP Proxy → Datadog / Splunk

The agent talks to **one** MCP server — the MCP Proxy (`:8290`). The proxy
federates the Splunk (`:8400`) and Datadog (`:8401`) MCP backends and routes each
namespaced tool call to its origin.

Paste the Mermaid block below into [mermaid.live](https://mermaid.live) or any compatible renderer.

```mermaid
sequenceDiagram
    autonumber
    actor Operator
    participant Agent as DevOps Oversight Agent<br/>:8000
    participant Proxy as MCP Proxy<br/>:8290
    participant SplunkMCP as Splunk MCP<br/>:8400
    participant DatadogMCP as Datadog MCP<br/>:8401

    Operator->>Agent: POST /investigate<br/>{ service, severity, description }

    Note over Agent,Proxy: initMcp() — one connection to the proxy

    Agent->>Proxy: initialize + tools/list
    Note over Proxy: ensureFederation() on first request

    Proxy->>SplunkMCP: initialize + tools/list
    SplunkMCP-->>Proxy: 4 splunk_* tools
    Proxy->>DatadogMCP: initialize + tools/list
    DatadogMCP-->>Proxy: 8 datadog_*/apm_* tools
    Note over Proxy: registry = topology__(11) + splunk__(4) + datadog__(8)<br/>tools/list returns only discover_tools + topology__

    Proxy-->>Agent: discover_tools + 11 topology__ tools
    Note over Agent: activeTools seeded — Splunk/Datadog tools NOT yet in context

    Agent->>Agent: runConfiguredLlm(systemPrompt, prompt, activeTools, …)

    loop LLM tool-use loop (up to 30 turns)

        Agent->>Proxy: tools/call topology__get_dependencies
        Note over Proxy: strip topology__ → local dispatchTool
        Proxy-->>Agent: dependency graph JSON

        Agent->>Proxy: tools/call discover_tools("Splunk log 502")
        Note over Proxy: searchRegistry → top-k manifests
        Proxy-->>Agent: { tools: [ splunk__splunk_run_query, … ] }
        Agent->>Agent: absorbDiscovered → add schemas to activeTools

        Agent->>Proxy: tools/call splunk__splunk_run_query
        Note over Proxy: strip splunk__ → forward to Splunk backend
        Proxy->>SplunkMCP: tools/call splunk_run_query
        SplunkMCP-->>Proxy: log events JSON
        Proxy-->>Agent: log events JSON

        Agent->>Proxy: tools/call discover_tools("Datadog trace APM")
        Proxy-->>Agent: { tools: [ datadog__get_datadog_trace, … ] }
        Agent->>Agent: absorbDiscovered → add schemas to activeTools

        Agent->>Proxy: tools/call datadog__get_datadog_trace
        Note over Proxy: strip datadog__ → forward to Datadog backend
        Proxy->>DatadogMCP: tools/call get_datadog_trace
        DatadogMCP-->>Proxy: trace spans JSON
        Proxy-->>Agent: trace spans JSON

        Agent->>Proxy: tools/call topology__list_runbooks
        Proxy-->>Agent: runbook catalog

        Note over Agent: HITL guardrail — propose action, await approval before run_runbook
        Agent->>Operator: "I recommend disable-chaos on payment-service. Approve?"
        Operator->>Agent: approved

        Agent->>Proxy: tools/call topology__run_runbook { id: "disable-chaos" }
        Proxy-->>Agent: execution steps + audit log entry

    end

    Agent-->>Operator: investigation summary (root cause + actions taken)
```

## Key points

| Point | Detail |
|-------|--------|
| One connection | The agent opens a single MCP client — to the proxy. It never connects to Splunk/Datadog directly. |
| Proxy federates | On first request the proxy connects to both backends, lists their tools, and namespaces them into its registry (`ensureFederation`, lazy + non-fatal). |
| Lazy loading | `tools/list` returns only `discover_tools` + topology tools; Splunk/Datadog manifests are revealed on demand via `discover_tools`. |
| Prefix routing | The proxy strips `splunk__`/`datadog__`/`topology__` and forwards to the backend (or dispatches locally for topology). |
| HITL guardrail | The system prompt requires operator approval before `run_runbook` is ever called. |
| Mock↔live swap | Point `SPLUNK_MCP_URL`/`DATADOG_MCP_URL` at real SaaS MCPs on the proxy — the agent is unchanged. |
