# DevOps OverSight Agent — Presentations

Two WSO2-branded decks covering the DevOps Observability POC, both generated
from the same Python framework (`generator/decklib.py`) so they look and feel
consistent at two different altitudes.

## Files

| File | What it is |
|------|-----------|
| `DevOps-OverSight-Agent-POC-Review.pptx` / `.pdf` | **Deep dive (48 slides).** FDE team + engineering leadership. Full architecture, both solutions in detail, measured A/B results. |
| `DevOps-OverSight-Agent-Executive-Overview.pptx` / `.pdf` | **Executive overview (15 slides).** CEO/COO/CTO-level. Business framing, simplified architecture, the workflow cycle, and the headline measured numbers. |
| `generator/build_deck.py` | Builds the deep-dive deck. |
| `generator/build_exec_deck.py` | Builds the executive deck. |
| `generator/decklib.py` | Shared visual system (palette, cards, diagram primitives, tables) both decks import. |
| `measured-ab-results.csv` / `measured-ab-results-cloud.csv` | Raw per-run data from the local-model and cloud-model A/B tests (see below). |

---

## Executive Overview (15 slides)

Built for a CEO/COO/CTO audience — no ports, no tool names, no jargon. Structure:
title → executive summary → the business problem → what it is / how it works
(intro) → **the workflow cycle** (Detect → Investigate → Diagnose → Suggest a
runbook → **Approve** → Remediate & Recover) → a divider framing the two
solutions → simplified architecture for each solution → **measured results
table** (cloud-model reliability + speed, plus the local-vs-cloud reliability
finding as a cost/build-vs-buy data point) → governance & trust (the approval
gate, bounded actions, audit trail) → no vendor lock-in → the 5-minute demo →
where things stand (a business-level read, not a placeholder) → next steps →
close.

It deliberately gives a clearer point of view than the deep dive's open
recommendation slide, since an executive audience expects a read, not just a
scorecard — but stays honest about what would tip the balance either way.

---

## Deep Dive (48 slides)

## Audience & framing (as scoped)

- **Internal only** — FDE team + leadership. (No separate client cut yet; derive one later from this master.)
- **Scorecard + measured verdict** — slide 41 is the honest qualitative side-by-side; slide 42 (**Recommendation**) is backed by a real A/B benchmark run on **two models**, 18 runs each (3 datasets × 6):
  - **Local `qwen2.5:14b` (Ollama):** LangChain more reliable (61% vs 28% correct-proposal; Ballerina hit 0/6 in one dataset) and faster (~62s vs ~78s).
  - **Cloud `claude-haiku-4-5` (Anthropic):** both **100% reliable**, and the **speed winner flips** — **Ballerina ~2.6× faster** (~14s vs ~36s), because with fast inference its ~9 LLM calls beat LangChain's ~19 network round-trips.
  - **Takeaway:** model choice matters more than architecture for reliability (local flakiness → 100% on a real model); on the model you'd actually deploy both are reliable and Ballerina is faster, so runtime stops deciding it and the qualitative scorecard + client context do. Raw data: [`measured-ab-results.csv`](measured-ab-results.csv) (local) and [`measured-ab-results-cloud.csv`](measured-ab-results-cloud.csv) (Haiku); harnesses in [`generator/`](generator/).
- **WSO2-branded** — orange (`#FF7300`) on a clean light theme; dark section dividers.
- **Deep dive** — ~48 slides, per-slide speaker notes / talk track.

## Structure

1. **Front matter** — title, agenda, executive summary
2. **§1 The Problem** — silo tax, manual-correlation cost, three forces, stakeholders, the POC bar
3. **§2 Level 0 Architecture** — two tiers, the mesh, telemetry fan-out, MCP, trace_id correlation (+ the 64/128-bit gotcha), the agent's job & approval gate, the 10-step flow, WSO2 AMP, model flexibility, the fork
4. **§3 Ballerina + MCP Proxy** — overview, architecture, why a proxy, lazy tool loading, prefix routing, investigation loop, stack/tools/runbooks, strengths & limits
5. **§4 LangChain + A2A** — overview, architecture, the A2A protocol, low-context by decomposition, the hard approval gate, investigation loop, stack & Timeout Chain, strengths & limits
6. **§5 Comparison & Path Forward** — the architectural crux, scorecard, **recommendation (measured, local vs. cloud)**, the 5-minute demo, POC→Enterprise hardening, cross-cutting gotchas, summary & next steps, ports appendix, closing

## Editing tips (either deck)

- **Small text edits:** just edit the `.pptx` directly.
- **Structural / repeatable changes** (new slide, palette tweak, rename a component everywhere): edit `generator/build_deck.py` (deep dive) or `generator/build_exec_deck.py` (executive) and regenerate. Slide content lives in one function per slide; the visual system (colors, fonts, cards, diagrams, tables) lives in `generator/decklib.py` and is shared by both.
- **Branding:** all colors are constants at the top of `generator/decklib.py`. The `wso2` wordmark is drawn as text; drop in a real logo image if you'd rather.
- **Client cut of the deep dive:** trim the "honest limits" and internal-scoping slides, soften the gotchas. The generator makes this a quick fork of `build_deck.py` — or start from the executive deck, which is already closer to client-ready.

## Regenerating

Requires `python-pptx`:

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install python-pptx
python generator/build_deck.py       # deep dive -> DevOps-OverSight-Agent-POC-Review.pptx
python generator/build_exec_deck.py  # executive -> DevOps-OverSight-Agent-Executive-Overview.pptx
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
- **The measured numbers in both decks are the same underlying data**, just presented at different resolution: the deep dive shows the full local-vs-cloud matrix (slide 42); the executive deck shows only the cloud-model headline (100%/100% reliability, 14s/36s) plus the local-vs-cloud reliability gap as a one-line cost/build-vs-buy footnote. Neither deck overclaims — the executive deck's methodology line and speaker notes carry the same caveats (N=18 per stack, 3 independent batches, sequential runs, mock backends).
