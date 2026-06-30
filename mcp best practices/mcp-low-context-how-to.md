# How to Keep MCPs Low-Context
**Engineering Reference — Based on Field Reports**

---

## Overview

As MCP tool catalogs grow, naive approaches flood the model's context window with hundreds of tool manifests on every turn. This guide covers five architectural patterns to keep that footprint small, deterministic, and fast. Each section describes the problem, the solution, implementation steps, and tradeoffs.

---

## Pattern 1: Expose Minimal Surface (Split Large MCP Servers)

### Problem

A single large MCP server exposing 30–50 tools injects every manifest into context on every turn — even for tasks that only need 2 or 3 of them. This wastes tokens, confuses routing, and increases latency.

### Solution

Break large MCP servers into smaller, semantically cohesive units. Each server should represent a single capability domain (e.g., "file ops," "API calls," "database queries"). A practical ceiling is **4 servers per software component**.

### How to Implement

1. Audit your existing MCP server(s) and list all exposed tools.
2. Group tools by semantic domain (nouns they operate on, or workflows they belong to).
3. Create a separate MCP server binary/process per group.
4. Update client configs (`mcp.json` or equivalent) to reference the new servers.
5. Run a smoke test: confirm each server loads only tools from its domain.

**Example split for an API platform MCP:**
```
apim-admin-mcp     → tenant/user/policy management tools
apim-analytics-mcp → metrics, logs, usage queries
apim-dev-portal-mcp → app/subscription/key management
```

### Tradeoffs

| Pro | Con |
|-----|-----|
| Each turn loads only the relevant server | More processes to deploy and monitor |
| Easier to version and update individual domains | Requires cross-server coordination for multi-domain tasks |
| Smaller blast radius if a server misbehaves | Initial refactor effort |

---

## Pattern 2: Lazy Tool Loading / Deferred Discovery

### Problem

Injecting all tool manifests at session start means the model pays the context cost for every registered tool on turn 1 — before it even knows what the user wants.

### Solution

Instead of injecting tool manifests upfront, expose a single **ToolSearch** (or `discover_tools`) tool. When the agent needs a capability, it queries the discovery tool with a natural language description, gets back the top-k relevant manifests, and those manifests are injected for the *next* turn only.

### How to Implement

1. Create a `tool_search` MCP tool that accepts a `query: string` and returns `Array<ToolManifest>`.
2. Back it with a searchable index (see Pattern 3 for the registry approach).
3. Remove all other tools from the initial context injection.
4. Instruct your system prompt: *"Use `tool_search` before calling any tool you haven't confirmed is available."*
5. On the next turn, inject only the returned manifests alongside the conversation history.

**System prompt snippet:**
```
You have access to one tool: `tool_search(query)`.
Call it with a description of what you need before attempting any other tool call.
```

### Tradeoffs

| Pro | Con |
|-----|-----|
| Near-zero manifest cost on turn 1 | Adds one extra round-trip before first tool use |
| Scales to hundreds of tools without context pressure | Discovery accuracy depends on index quality |
| Model only ever sees relevant tools | Requires maintaining the discovery index |

---

## Pattern 3: Semantic Router / Tool Registry

### Problem

Even with deferred loading, you need a reliable way to match a natural-language request to the right tool manifest. Keyword search is brittle; loading everything to let the model decide defeats the purpose.

### Solution

Build a **tool registry** backed by a semantic graph or vector index. The router accepts a query, embeds it, and returns the **top-k** most relevant tool manifests. Only those manifests enter the model's context.

### How to Implement

1. For each tool, write a rich natural-language description and embed it (e.g., using `nomic-embed-text` via Ollama on `prod.aten`).
2. Store embeddings in a vector store (pgvector is already available in your stack).
3. Expose a `discover_tools(query, k=5)` endpoint that performs cosine similarity search and returns the top-k tool schemas.
4. Wire this endpoint as the single entry-point tool in the model's initial context.
5. Tune `k` — start at 5, raise if the agent frequently needs follow-up discovery calls.

**Pseudocode:**
```python
def discover_tools(query: str, k: int = 5) -> list[ToolSchema]:
    embedding = embed(query)
    results = pgvector_search(embedding, k=k)
    return [load_schema(r.tool_id) for r in results]
```

### Tradeoffs

| Pro | Con |
|-----|-----|
| Scales to 100+ tools with low context cost | Embedding quality determines routing accuracy |
| Semantic matching handles paraphrasing and synonyms | Cold-start: all tools must be indexed before use |
| Single discovery interface, easily versioned | Needs vector infrastructure (already available: pgvector + Ollama) |

---

## Pattern 4: Higher-Level Abstractions (Skills, CLIs, Subagents)

### Problem

Fine-grained tools (one per API endpoint, one per file operation) explode manifest count and require the model to chain many calls to complete a task. The manifest overhead compounds quickly.

### Solution

Replace clusters of fine-grained tools with **higher-level abstractions**:

- **Skills** — encapsulate a workflow behind a single callable with structured I/O
- **CLI bridges** — let the model issue shell commands through a single `run_cli(command)` tool instead of loading individual tool schemas
- **Subagents** — offload heavy-tool workflows (Playwright, Figma, large API clients) to a child agent that runs its own context window

### How to Implement

**Option A — Skills:**
1. Identify clusters of 3–5 tools always called together.
2. Write a skill function that orchestrates them server-side.
3. Expose the skill as a single MCP tool with a descriptive schema.

**Option B — CLI Bridge:**
1. Wrap your toolset in a CLI (`my-tool-cli --action list-users --filter active`).
2. Expose a single `run_cli(command: string)` MCP tool.
3. The model discovers available commands via `run_cli("--help")` rather than loading manifests.

**Option C — Subagents:**
1. For heavy MCPs (Playwright, etc.), spin a child agent process with its own system prompt and tool set.
2. Expose the child agent to the parent as a single `delegate_to_browser_agent(task: string)` tool.
3. The parent never sees Playwright's manifests — only the delegated result.

### Tradeoffs

| Pro | Con |
|-----|-----|
| Dramatically reduces parent context size | Skills require upfront engineering |
| Subagents can run specialized, pre-warmed contexts | CLI execution carries security risk (see Safety section) |
| CLIs are discoverable via `--help` without embedding | Subagents add orchestration complexity |

---

## Pattern 5: Per-Session Tool Sets / Project Scoping

### Problem

A single `mcp.json` that loads every registered server means a developer debugging a Fidelity integration also has Playwright, Figma, and database admin tools in context — irrelevant noise that costs tokens and creates risk.

### Solution

Maintain **multiple tool-set configuration files** and select the appropriate one per session or project. The agent only loads tools relevant to the current task scope.

### How to Implement

1. Create a base `mcp.json` with discovery-only tools (see Pattern 2).
2. Create scoped config files:
   - `mcp.apim.json` — APIM admin tools
   - `mcp.infra.json` — Docker, SSH, systemd tools
   - `mcp.analytics.json` — metrics, log queries
3. Pass the config at session start:
   ```
   claude --mcp-config mcp.apim.json
   ```
   Or set via environment variable / project `.claude/` directory.
4. Document which config to use for which project in your team wiki.

**Directory layout:**
```
.claude/
  mcp.default.json     ← discovery + common utils only
  mcp.apim.json        ← APIM-scoped tools
  mcp.fidelity.json    ← Fidelity engagement toolset
  mcp.homelab.json     ← prod.aten / dev.aten tools
```

### Tradeoffs

| Pro | Con |
|-----|-----|
| Zero irrelevant tools in context for any given session | Requires discipline to pick the right config |
| Easy to audit what tools an agent session can access | Config files can drift from actual server state |
| Reduces accidental cross-domain tool invocations | Multi-domain tasks may need a merged config |

---

## Safety & Security Notes

These patterns increase power but introduce risks that need explicit guardrails:

**CLI / Execute Gateway Risk**
A `run_cli` tool running as your user can execute destructive operations. Mitigations:
- Run CLI bridges as a dedicated low-privilege service account.
- Allowlist permitted commands; reject anything not on the list.
- Log all invocations with the originating prompt context.

**Sandbox Choice for Code Mode**
If using a code-mode executor (Pattern 1/2 complement), choose the sandbox carefully:
- **`quickjs-emscripten`** — safer for adversarial inputs; fewer known escapes.
- **`RestrictedPython`** — has known escape vectors; avoid for untrusted inputs.

**Prompt Injection via Tool Results**
Tool results containing attacker-controlled text can hijack routing. Always strip or escape result content before it re-enters the agent loop as context.

---

## Quick-Reference Checklist

```
[ ] Split large MCP servers into ≤4 semantic units per component
[ ] Add a ToolSearch/discover_tools gateway; remove upfront manifest injection
[ ] Back the registry with pgvector + nomic-embed-text (already in stack)
[ ] Replace fine-grained tool clusters with Skills, CLI bridges, or Subagents
[ ] Create per-project mcp.*.json files; document which config maps to which engagement
[ ] Restrict CLI/execute tools to a least-privilege service account
[ ] Choose quickjs-emscripten over RestrictedPython for any code-mode sandbox
```

---

*Last updated: June 2026*
