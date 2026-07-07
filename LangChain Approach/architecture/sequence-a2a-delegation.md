# Sequence — A2A delegation (message level)

How one `ask_datadog_agent(...)` tool call becomes an A2A round-trip and comes
back as evidence. `ask_splunk_agent` is identical against SplunkAgent :8102.

## Startup (once, in the orchestrator lifespan)

```
init_a2a_clients(httpx_client):
  for each specialist URL (DATADOG_AGENT_URL, SPLUNK_AGENT_URL):
    A2ACardResolver(httpx, url).get_agent_card()      # retry until the agent is up
    ClientFactory(ClientConfig(httpx_client, streaming=True)).create(card)
  → _clients = {"datadog": <Client>, "splunk": <Client>}
```

Each specialist, at *its* startup, eagerly loads its MCP tools
(`DataDogMCPClient().load_tools()` → `langchain-mcp-adapters` over
streamable-HTTP), builds a `create_agent` ReAct loop, and serves A2A JSON-RPC
via `A2AStarletteApplication` (agent-card route + JSON-RPC route).

## Per delegate call

```
Orchestrator LLM emits tool call: ask_datadog_agent("payment-service: which
    monitors alert, error-rate/latency last 30m, one sample trace_id")
   │
   ▼  a2a_clients._ask("datadog", request)
SendMessageRequest(message = new_text_message(request, role=ROLE_USER))
   │  client.send_message(req)  →  JSON-RPC POST to http://datadog-agent:8101/
   ▼                               (httpx propagates traceparent)
DataDogAgent: DefaultRequestHandler → DataDogAgentExecutor.execute(context, queue)
   │  text = context.get_user_input()
   │  result = await create_agent(...).ainvoke({"messages":[HumanMessage(text)]})
   │     LangChain ReAct loop calls MCP tools:
   │        search_datadog_monitors → get_datadog_metric → apm_search_spans
   │        (streamable-HTTP tools/call to datadog-mock-mcp:8401/mcp)
   │  event_queue.enqueue_event(new_text_message(final_text, role=ROLE_AGENT))
   ▼
Orchestrator: async for resp in client.send_message(...):
                 out += get_stream_response_text(resp)
   → "Monitor 'payment 5xx' ALERT; error 0.02→0.31 at 14:02; p95 2.4s;
      sample trace_id abc123def456789012345678deadbeef; bottleneck span
      mock-bank charge 2.0s"
   (returned to the orchestrator LLM as the tool result)
```

## Why a plain agent Message, not a Task

The specialists answer a single request/response — no long-running Task
lifecycle is needed. The executor enqueues one agent `Message`; the client reads
it back with `get_stream_response_text`. (This is the shape the a2a-sdk v1.1
round-trip spike confirmed, and the regression test in
`oversight_common/tests/test_a2a_server.py` guards it.)

## The output contract is load-bearing

Evidence crosses the A2A boundary as prose. If a specialist returns a vague
summary (missing the `trace_id`, no timestamps, no values), the orchestrator —
which fuses everything in one context — is starved. That is why the specialist
system prompts mandate: always include any `trace_id` verbatim, concrete metric
values with timestamps, monitor states, and span breakdowns.
