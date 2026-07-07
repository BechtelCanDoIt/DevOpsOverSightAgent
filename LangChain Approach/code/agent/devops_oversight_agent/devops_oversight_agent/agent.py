"""The orchestrator graph and its hard propose-before-act gate.

The Ballerina agent enforced propose-before-act at the prompt level only — an
LLM that ignored the instruction could call run_runbook directly. Here it is a
code-level gate: HumanInTheLoopMiddleware physically interrupts the graph before
``topology__run_runbook`` executes. ``/investigate`` returns the proposal + a
sessionId; the operator approves via ``/chat`` on that session, which resumes
the graph and only then runs the runbook. An InMemorySaver checkpointer keys
the paused state by thread_id (== sessionId).
"""

from __future__ import annotations

import logging

from langchain.agents import create_agent
from langchain.agents.middleware import HumanInTheLoopMiddleware
from langchain_core.messages import HumanMessage
from langgraph.checkpoint.memory import InMemorySaver
from langgraph.types import Command

from oversight_common.config import recursion_limit
from oversight_common.token_csv import TokenCsvCallback

from .a2a_clients import A2A_DELEGATE_TOOLS
from .prompts import SYSTEM_PROMPT
from .topology_tools import RUN_RUNBOOK_TOOL_NAME, TOPOLOGY_TOOLS

logger = logging.getLogger("oversight")

APPROVAL_WORDS = {"approve", "approved", "yes", "y", "ok", "okay", "go", "do it", "proceed", "confirm"}
REJECT_WORDS = {"reject", "rejected", "no", "n", "cancel", "stop", "deny", "abort"}


def build_orchestrator(model):
    """Compile the orchestrator ReAct graph with the interrupt gate + checkpointer."""
    middleware = [
        HumanInTheLoopMiddleware(
            interrupt_on={RUN_RUNBOOK_TOOL_NAME: {"allowed_decisions": ["approve", "reject"]}},
            description_prefix="Runbook execution requires operator approval",
        )
    ]
    return create_agent(
        model=model,
        tools=[*A2A_DELEGATE_TOOLS, *TOPOLOGY_TOOLS],
        system_prompt=SYSTEM_PROMPT,
        middleware=middleware,
        checkpointer=InMemorySaver(),
        name="devops-oversight-agent",
    )


def classify_decision(message: str) -> dict:
    """Map a free-text operator reply to a HITL decision. Anything not clearly
    an approval is treated as a rejection carrying the message (so the LLM can
    react), which keeps the gate fail-safe: only an explicit yes runs a runbook."""
    text = message.strip().lower()
    if text in APPROVAL_WORDS or any(text.startswith(w + " ") for w in APPROVAL_WORDS):
        return {"type": "approve"}
    return {"type": "reject", "message": f"Operator did not approve: {message}"}


def _final_text(result) -> str:
    messages = result.get("messages", []) if isinstance(result, dict) else []
    for msg in reversed(messages):
        content = getattr(msg, "content", None)
        if isinstance(content, str) and content.strip():
            return content
        if isinstance(content, list):
            joined = "".join(b.get("text", "") for b in content if isinstance(b, dict)).strip()
            if joined:
                return joined
    return "(no response)"


def _render_proposal(interrupts) -> str:
    """Human-readable proposal text from the pending HITL interrupt(s)."""
    lines = ["PROPOSAL — awaiting your approval (reply 'approve' on this sessionId to run, or 'reject'):"]
    for interrupt in interrupts:
        value = interrupt.value
        requests = value.get("action_requests", []) if isinstance(value, dict) else []
        for req in requests:
            action = req.get("action") or req.get("name") or "runbook"
            args = req.get("args", {})
            lines.append(f"- {action} {args}")
            if req.get("description"):
                lines.append(f"  {req['description']}")
    return "\n".join(lines)


async def _config(session_id: str) -> dict:
    return {
        "configurable": {"thread_id": session_id},
        "recursion_limit": recursion_limit(),
        "callbacks": [TokenCsvCallback(model_fallback="devops-oversight-agent")],
    }


async def run_turn(agent, message: str, session_id: str) -> dict:
    """Drive one orchestrator turn on a session.

    If the session is paused at a runbook proposal, ``message`` is interpreted
    as the approval decision and the graph resumes. Otherwise it's a new user
    message. Returns {"status": "proposal"|"done", "text", "session_id"}.
    """
    config = await _config(session_id)
    snapshot = await agent.aget_state(config)
    pending = bool(getattr(snapshot, "interrupts", ()) or ())

    if pending:
        decision = classify_decision(message)
        result = await agent.ainvoke(Command(resume={"decisions": [decision]}), config)
    else:
        result = await agent.ainvoke({"messages": [HumanMessage(message)]}, config)

    interrupts = result.get("__interrupt__") if isinstance(result, dict) else None
    if interrupts:
        return {"status": "proposal", "text": _render_proposal(interrupts), "session_id": session_id}
    return {"status": "done", "text": _final_text(result), "session_id": session_id}
