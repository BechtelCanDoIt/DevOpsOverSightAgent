# DevOps OverSight Agent — POC Architecture Review (Presentation)

A WSO2-branded, 48-slide deep-dive deck covering the DevOps Observability POC:
the shared **Level 0** architecture and the two reference solutions
(**Ballerina + MCP Proxy** and **LangChain + A2A**).

## Files

| File | What it is |
|------|-----------|
| `DevOps-OverSight-Agent-POC-Review.pptx` | **The deck.** Fully editable in PowerPoint / Keynote / Google Slides. Speaker notes on every content slide. |
| `DevOps-OverSight-Agent-POC-Review.pdf` | Flat PDF for quick viewing / emailing. |
| `generator/` | The Python that builds the `.pptx` — edit content here and regenerate, rather than hand-tweaking XML. |

## Audience & framing (as scoped)

- **Internal only** — FDE team + leadership. (No separate client cut yet; derive one later from this master.)
- **Scorecard + measured verdict** — slide 41 is the honest qualitative side-by-side; slide 42 (**Recommendation**) is backed by a real A/B benchmark (identical `qwen2.5:14b-instruct` on Ollama, **18 runs each = 3 datasets × 6**). Headline: on the local model **LangChain won both axes** — faster (~62s vs ~78s median time-to-proposal) and **~2× more reliable** (61% vs 28% correct-proposal rate; Ballerina hit 0/6 in one dataset). This overturned the architecture-first prediction (which favored Ballerina on both). Both are still sub-production on a local model → use a cloud model for demo/prod. Raw per-run data in [`measured-ab-results.csv`](measured-ab-results.csv); harness in [`generator/measure.sh`](generator/measure.sh). The final verdict still weighs client team/governance context on top of these numbers.
- **WSO2-branded** — orange (`#FF7300`) on a clean light theme; dark section dividers.
- **Deep dive** — ~48 slides, per-slide speaker notes / talk track.

## Structure

1. **Front matter** — title, agenda, executive summary
2. **§1 The Problem** — silo tax, manual-correlation cost, three forces, stakeholders, the POC bar
3. **§2 Level 0 Architecture** — two tiers, the mesh, telemetry fan-out, MCP, trace_id correlation (+ the 64/128-bit gotcha), the agent's job & approval gate, the 10-step flow, WSO2 AMP, model flexibility, the fork
4. **§3 Ballerina + MCP Proxy** — overview, architecture, why a proxy, lazy tool loading, prefix routing, investigation loop, stack/tools/runbooks, strengths & limits
5. **§4 LangChain + A2A** — overview, architecture, the A2A protocol, low-context by decomposition, the hard approval gate, investigation loop, stack & Timeout Chain, strengths & limits
6. **§5 Comparison & Path Forward** — the architectural crux, scorecard, **recommendation (placeholder)**, the 5-minute demo, POC→Enterprise hardening, cross-cutting gotchas, summary & next steps, ports appendix, closing

## Editing tips

- **Small text edits:** just edit the `.pptx` directly.
- **Structural / repeatable changes** (new slide, palette tweak, rename a component everywhere): edit `generator/build_deck.py` and regenerate. Slide content lives in one function per slide; the visual system (colors, fonts, cards, diagrams, tables) lives in `generator/decklib.py`.
- **Branding:** all colors are constants at the top of `generator/decklib.py`. The `wso2` wordmark is drawn as text; drop in a real logo image if you'd rather.
- **Client cut:** trim the "honest limits" and internal-scoping slides, soften the gotchas, and complete the recommendation. The generator makes this a quick fork of `build_deck.py`.

## Regenerating

Requires `python-pptx`:

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install python-pptx
python generator/build_deck.py     # writes the .pptx into this folder
```

Optional visual QA (render every slide to PNG) needs LibreOffice + `pypdfium2`:

```bash
pip install pypdfium2 Pillow
# generator/render.sh expects a sibling pptx-venv; adjust the PY path or run soffice by hand:
/Applications/LibreOffice.app/Contents/MacOS/soffice --headless --convert-to pdf \
  --outdir . DevOps-OverSight-Agent-POC-Review.pptx
```

## Accuracy notes (worth a glance before presenting)

- Content is drawn from the repo's `business requirements/`, both approaches' `architecture.md`/`README.md`, and code. Component names, ports, tool catalogs, and the demo `trace_id` are quoted as-built.
- A couple of real repo discrepancies were handled honestly rather than papered over:
  - **Local model default:** docs recommend `qwen2.5:14b-instruct`; the code fallback is `qwen3.5:9b`. The deck says "qwen2.5 / qwen3.5 family."
  - **Agent port:** shows as `:8000` (code), `:8092` (compose host), `:8080` (AMP). The deck uses `:8092` for the compose demo.
  - **WSO2 AMP role** differs by solution (agent runtime in S1; optional LLM gateway in S2) — called out explicitly on the AMP slide.
