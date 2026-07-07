"""Shared agent-tier configuration: env helpers, turn budget, the Timeout Chain.

The Timeout Chain is the classic cross-process failure mode in this topology:
if an inner timeout outlives an outer one, the orchestrator sees opaque A2A
errors mid-investigation. Keep it strictly ordered, largest outermost:

    uvicorn (600s) > A2A client (300s) > sub-agent LLM (180s) > MCP call (30s)

`assert_timeout_chain()` runs at orchestrator startup and fails fast on
misordering.
"""

from __future__ import annotations

import os


def env_or(name: str, fallback: str) -> str:
    """Read an env var, falling back to a default when unset or empty."""
    v = os.environ.get(name, "")
    return v if v != "" else fallback


def max_turns() -> int:
    """Agent turn budget. Do NOT go below 25 — Ollama non-determinism means
    some investigations legitimately need 25-28 turns (parity with the
    Ballerina agent's maxTurns=30)."""
    return int(env_or("MAX_TURNS", "30"))


def recursion_limit() -> int:
    """LangGraph steps per turn: one model step + one tool step, plus one to finish."""
    return 2 * max_turns() + 1


def uvicorn_timeout_s() -> int:
    return int(env_or("UVICORN_TIMEOUT_S", "600"))


def a2a_timeout_s() -> int:
    return int(env_or("A2A_TIMEOUT_S", "300"))


def llm_timeout_s() -> int:
    return int(env_or("LLM_TIMEOUT_S", "180"))


def mcp_timeout_s() -> int:
    return int(env_or("MCP_TIMEOUT_S", "30"))


def assert_timeout_chain() -> None:
    chain = [
        ("UVICORN_TIMEOUT_S", uvicorn_timeout_s()),
        ("A2A_TIMEOUT_S", a2a_timeout_s()),
        ("LLM_TIMEOUT_S", llm_timeout_s()),
        ("MCP_TIMEOUT_S", mcp_timeout_s()),
    ]
    for (outer_name, outer), (inner_name, inner) in zip(chain, chain[1:]):
        if outer <= inner:
            raise RuntimeError(
                f"Timeout Chain violated: {outer_name}={outer}s must be strictly greater "
                f"than {inner_name}={inner}s (largest outermost, or the orchestrator sees "
                f"opaque A2A errors mid-investigation)"
            )


def chaos_token() -> str:
    return env_or("CHAOS_TOKEN", "dev-chaos-token")
