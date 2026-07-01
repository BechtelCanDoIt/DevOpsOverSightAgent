# Sequence Diagram — Overview: Agent → MCP Servers → Datadog / Splunk

Paste the Mermaid block below into [mermaid.live](https://mermaid.live) or any compatible renderer.

```mermaid
sequenceDiagram
    autonumber
    actor Operator
    participant Agent as DevOps Oversight Agent<br/>:8000
    participant TopologyMCP as MCP Proxy (Topology)<br/>:8290
    participant SplunkMCP as Splunk Mock MCP<br/>:8400
    participant DatadogMCP as Datadog Mock MCP<br/>:8401

    Operator->>Agent: POST /investigate<br/>{ service, severity, description }

    Note over Agent: initMcp() — connect & handshake all 3 servers

    Agent->>TopologyMCP: initialize + tools/list
    TopologyMCP-->>Agent: 11 topology/correlation/runbook tools

    Agent->>SplunkMCP: initialize + tools/list
    SplunkMCP-->>Agent: 4 splunk_* tools (stored in registry only)

    Agent->>DatadogMCP: initialize + tools/list
    DatadogMCP-->>Agent: 8 datadog_*/apm_* tools (stored in registry only)

    Note over Agent: activeTools = [discover_tools] + 11 topology tools<br/>Splunk & Datadog tools are in registry, NOT yet in context

    Agent->>Agent: runConfiguredLlm(systemPrompt, prompt, activeTools, …)

    loop LLM tool-use loop (up to 30 turns)

        Agent->>Agent: LLM picks topology tool<br/>e.g. topology__get_dependencies
        Agent->>TopologyMCP: tools/call → get_dependencies
        TopologyMCP-->>Agent: dependency graph JSON
        Agent->>Agent: result appended to conversation

        Agent->>Agent: LLM calls discover_tools("Splunk logs 502")
        Agent->>Agent: searchRegistry() — keyword score & top-5 match
        Agent->>Agent: matching splunk__* schemas added to activeTools

        Agent->>Agent: LLM picks splunk__splunk_run_query
        Agent->>SplunkMCP: tools/call → splunk_run_query
        SplunkMCP-->>Agent: log events JSON
        Agent->>Agent: result appended to conversation

        Agent->>Agent: LLM calls discover_tools("Datadog trace APM")
        Agent->>Agent: searchRegistry() — keyword score & top-5 match
        Agent->>Agent: matching datadog__* schemas added to activeTools

        Agent->>Agent: LLM picks datadog__get_datadog_trace
        Agent->>DatadogMCP: tools/call → get_datadog_trace
        DatadogMCP-->>Agent: trace spans JSON
        Agent->>Agent: result appended to conversation

        Agent->>Agent: LLM calls topology__list_runbooks
        Agent->>TopologyMCP: tools/call → list_runbooks
        TopologyMCP-->>Agent: runbook catalog

        Note over Agent: HITL guardrail — agent must propose action<br/>and receive operator approval before run_runbook

        Agent->>Operator: "I recommend disable-chaos on payment-service.<br/>Approve?"
        Operator->>Agent: approved

        Agent->>TopologyMCP: tools/call → run_runbook { id: "disable-chaos" }
        TopologyMCP-->>Agent: execution steps + audit log entry

    end

    Agent-->>Operator: investigation summary (root cause + actions taken)
```

## Key points

| Point | Detail |
|-------|--------|
| Three direct connections | The agent connects to all three MCP servers independently — Splunk/Datadog do NOT route through the Topology MCP proxy |
| Lazy loading | Only `discover_tools` + topology tools are in the LLM context at turn 1; Splunk/Datadog schemas load on demand |
| Namespace prefixes | Tools are registered as `splunk__*`, `datadog__*`, `topology__*`; the dispatcher strips the prefix before forwarding |
| HITL guardrail | System prompt requires operator approval before `run_runbook` is ever called |
| maxTurns | Capped at 30 to absorb `discover_tools` round-trips and Ollama non-determinism |
