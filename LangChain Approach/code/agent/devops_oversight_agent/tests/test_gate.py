"""The load-bearing guardrail test: the propose-before-act gate.

Uses a scripted fake tool-calling model (no LLM) that emits a
topology__run_runbook call. The graph MUST interrupt before the runbook
executes; the runbook only runs after an explicit 'approve' resume, and a
'reject' must leave it un-executed.
"""

from __future__ import annotations

import pytest
from langchain_core.language_models.fake_chat_models import FakeMessagesListChatModel
from langchain_core.messages import AIMessage

from devops_oversight_agent import audit, runbooks
from devops_oversight_agent.agent import build_orchestrator, classify_decision, run_turn


@pytest.fixture(autouse=True)
def clean_audit():
    audit.reset_for_tests()


@pytest.fixture(autouse=True)
def no_real_chaos_call(monkeypatch):
    """disable-chaos would POST to a service :9099 — stub the executor so the
    gate test needs no network, while still recording the audit entry."""
    executed: list[tuple[str, dict]] = []

    async def fake_execute(runbook_id, params):
        executed.append((runbook_id, params))
        audit.append_audit(f"RUNBOOK {runbook_id} {params}")
        return [f"[stub] executed {runbook_id}"]

    monkeypatch.setattr(runbooks, "execute_runbook", fake_execute)
    # topology_tools imported the symbol; patch there too
    from devops_oversight_agent import topology_tools
    monkeypatch.setattr(topology_tools.runbooks, "execute_runbook", fake_execute)
    return executed


def _run_runbook_call():
    return AIMessage(
        content="Proposing disable-chaos for payment-service.",
        tool_calls=[{
            "name": "topology__run_runbook",
            "args": {"id": "disable-chaos", "params": {"service": "payment-service"}},
            "id": "call_rb_1",
            "type": "tool_call",
        }],
    )


class ScriptedToolModel(FakeMessagesListChatModel):
    """Replays scripted AIMessages; bind_tools is a no-op (the script already
    contains the tool calls), which create_agent requires."""

    def bind_tools(self, tools, **kwargs):  # noqa: ARG002
        return self


def _scripted_model(final_text: str):
    # 1st model turn: emit the runbook tool call. 2nd turn (after the tool runs
    # post-approval, or after the rejection message): a plain final answer.
    return ScriptedToolModel(responses=[_run_runbook_call(), AIMessage(content=final_text)])


def test_classify_decision():
    assert classify_decision("approve") == {"type": "approve"}
    assert classify_decision("yes") == {"type": "approve"}
    assert classify_decision("approve the disable-chaos runbook")["type"] == "approve"
    assert classify_decision("no")["type"] == "reject"
    assert classify_decision("what does it do?")["type"] == "reject"  # fail-safe


async def test_gate_interrupts_before_execution(no_real_chaos_call):
    agent = build_orchestrator(_scripted_model("Remediated."))
    first = await run_turn(agent, "investigate payment-service", "sess-gate-1")
    assert first["status"] == "proposal"
    assert "disable-chaos" in first["text"]
    assert no_real_chaos_call == []  # NOT executed yet — the gate held


async def test_gate_executes_after_approval(no_real_chaos_call):
    agent = build_orchestrator(_scripted_model("Remediated: chaos disabled."))
    session = "sess-gate-2"
    first = await run_turn(agent, "investigate payment-service", session)
    assert first["status"] == "proposal"
    second = await run_turn(agent, "approve", session)
    assert second["status"] == "done"
    assert no_real_chaos_call == [("disable-chaos", {"service": "payment-service"})]
    assert any("disable-chaos" in e for e in audit.get_audit_log())


async def test_gate_rejection_does_not_execute(no_real_chaos_call):
    agent = build_orchestrator(_scripted_model("Understood, holding off."))
    session = "sess-gate-3"
    await run_turn(agent, "investigate payment-service", session)
    second = await run_turn(agent, "no, leave it", session)
    assert second["status"] == "done"
    assert no_real_chaos_call == []  # rejection => never executed
    assert audit.get_audit_log() == []
