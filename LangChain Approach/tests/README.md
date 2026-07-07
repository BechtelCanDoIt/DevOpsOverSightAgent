# Tests

Three layers, mirroring the Ballerina sibling's `tests/`:

## `runUnitTests.sh` — unit (infra-free)

`uv run pytest` across the whole workspace. DB/Redis/NATS clients are lazy
factories that tests monkeypatch, so **no Postgres/Redis/NATS is required** (a
deliberate improvement over the Ballerina stack's infra-up-first requirement).
`OTEL_SDK_DISABLED=true` keeps tests off the collector.

```bash
./tests/runUnitTests.sh            # all
./tests/runUnitTests.sh generate   # just the mesh
./tests/runUnitTests.sh agent/devops_oversight_agent   # just the orchestrator + gate
```

Coverage highlights (~250 tests):
- **mesh_common** — chaos windows/probability/token auth, W3C traceparent build/parse, JSON log shape.
- **mesh services** — endpoint contracts, order saga error mappings (400/409/502/500/503) via respx-mocked downstreams, inventory cache read-through + reserve, invoice state machine, store graceful degradation, notification async-join (parsed trace_id), load-gen pattern parsing + spike window.
- **mock MCP servers** — every tool's exact result JSON vs the ported fixtures, incl. the Splunk trace-id-prefix and 502 filter heuristics; registered-tool-count checks (4 / 8).
- **oversight_common** — LLM provider factory (all four providers), Timeout-Chain assertion, token CSV golden row, and the **A2A round-trip** (executor → Starlette routes → A2A client) with a stub agent.
- **orchestrator** — trace-id normalization (the 64/128-bit gotcha, both widths), catalog dependency directions, runbook execution + audit, and the **propose-before-act gate**: the graph interrupts before `run_runbook`, executes only after `approve`, and never executes on `reject`.

## `runDockerConfigTests.sh` — docker-config (creds-free)

Brings up the mesh + mock MCP servers via compose and asserts: all 7 `/health`
UP (19091–19097), both mock MCPs UP (18400/18401), and the full chaos cycle on
payment-service (inject rate=1.0 → `/charge` 502 chaos-injected → reset → 201
approved). Flags: `--no-build`, `--no-start`, `--teardown`.

## `runA2AConfigTests.sh` — A2A config

Asserts both specialist AgentCards resolve at the well-known path (18101/18102)
and the orchestrator `/health` is UP; if an LLM is configured, it also runs a
canned `/investigate` and checks it returns a proposal + `sessionId` (without
executing a runbook). Flags: `--no-build`, `--no-start`, `--teardown`.
