# Sequence Diagram — Overview: Agent → MCP Proxy → Datadog / Splunk

The agent talks to **one** MCP server — the MCP Proxy (`:8290`). The proxy
federates the Splunk (`:8400`) and Datadog (`:8401`) MCP backends — and, when
configured, apim/mi/is/k8s (federation is data-driven and N-backend; see
`federation.bal` `backendDefs()`) — routing each namespaced tool call to its
origin. Splunk/Datadog are shown below as the two required demo-path backends.

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
    Note over Proxy: registry = topology__(15) + splunk__(4) + datadog__(8)<br/>tools/list returns only discover_tools + topology__

    Proxy-->>Agent: discover_tools + 15 topology__ tools
    Note over Agent: activeTools seeded — Splunk/Datadog tools NOT yet in context

    Agent->>Agent: runConfiguredLlm(systemPrompt, prompt, activeTools, …)

    loop LLM tool-use loop (up to 40 turns)

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

        Note over Agent: HARD approval gate — makeDispatcher intercepts run_runbook (approval.bal)
        Agent->>Agent: LLM emits tool_use topology__run_runbook { id: "disable-chaos" }
        Note over Agent: interceptRunRunbook — NOT forwarded to proxy;<br/>stores pending, returns RUNBOOK_HALT_MARKER sentinel
        Agent-->>Agent: "EXECUTION BLOCKED — approval token RB-1" (halts the loop)

    end

    Agent-->>Operator: summary + "Approval required: reply approve RB-1 (or deny RB-1)"

    Operator->>Agent: POST /chat { message: "approve RB-1" }
    Note over Agent: parseApprovalCommand (before the LLM) → handleApprovalCommand
    Agent->>Proxy: tools/call topology__run_runbook { id: "disable-chaos" }
    Proxy-->>Agent: execution steps + audit log entry
    Agent-->>Operator: "disable-chaos APPROVED and executed"
```

## Key points

| Point | Detail |
|-------|--------|
| One connection | The agent opens a single MCP client — to the proxy. It never connects to Splunk/Datadog directly. |
| Proxy federates | On first request the proxy connects to each configured backend, lists its tools, and namespaces them into its registry (`ensureFederation`, lazy + non-fatal). Splunk/Datadog are the two required demo defaults; apim/mi/is/k8s federate the same way when their URL is set. |
| Lazy loading | `tools/list` returns only `discover_tools` + topology tools; every backend's manifests (`splunk__`/`datadog__`/`apim__`/…) are revealed on demand via `discover_tools`. |
| Prefix routing | The proxy strips the `<label>__` prefix and forwards to that backend (`splunk__`/`datadog__`/`apim__`/`mi__`/`is__`/`k8s__`); `topology__` dispatches locally. |
| HITL guardrail | **Code-enforced, not prompt-only.** `makeDispatcher` intercepts `topology__run_runbook` (`approval.bal`) and never forwards it — the LLM gets a halt sentinel + token. Real execution runs only via a separate `approve <token>` chat message → `handleApprovalCommand`. Mirrors LangChain's `HumanInTheLoopMiddleware`. |
| Mock↔live swap | Point `SPLUNK_MCP_URL`/`DATADOG_MCP_URL` at real SaaS MCPs on the proxy — the agent is unchanged. |
