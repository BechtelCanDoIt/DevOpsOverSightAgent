"""A2A server round-trip test — proves the LangChainAgentExecutor + Starlette
routes + A2A client path end to end with a stub agent (no LLM, no MCP).

This is the spike that de-risked the a2a-sdk v1.1 protobuf API, kept as a
regression guard: a specialist agent's final text must reach an A2A caller.
"""

from __future__ import annotations

import asyncio
import threading
import time

import httpx
import pytest
import uvicorn
from a2a.client.card_resolver import A2ACardResolver
from a2a.client.client_factory import ClientConfig, ClientFactory
from a2a.helpers.proto_helpers import get_stream_response_text, new_text_message
from a2a.types import AgentSkill, Role, SendMessageRequest
from langchain_core.messages import AIMessage

from oversight_common.a2a_server import LangChainAgentExecutor, build_a2a_app, build_agent_card

PORT = 8207
URL = f"http://127.0.0.1:{PORT}"


class StubAgent:
    """Mimics a compiled LangChain agent: ainvoke -> {"messages": [...]}."""

    def __init__(self, reply: str):
        self.reply = reply
        self.seen: list[str] = []

    async def ainvoke(self, state, config):
        user_text = state["messages"][-1].content
        self.seen.append(user_text)
        return {"messages": [AIMessage(content=f"{self.reply} (re: {user_text})")]}


def _card():
    return build_agent_card(
        name="StubAgent",
        description="stub",
        url=URL,
        skill=AgentSkill(id="stub", name="Stub", description="stub", tags=["stub"]),
    )


def test_build_agent_card_fields():
    card = _card()
    assert card.name == "StubAgent"
    assert card.capabilities.streaming is True
    assert card.supported_interfaces[0].url == URL
    assert card.skills[0].id == "stub"


async def test_final_text_extraction_variants():
    from oversight_common.a2a_server import _final_text

    assert _final_text({"messages": [AIMessage(content="hello")]}) == "hello"
    # content-blocks form
    assert _final_text({"messages": [AIMessage(content=[{"type": "text", "text": "blocky"}])]}) == "blocky"
    assert _final_text({"messages": []}) == "(no response)"


@pytest.fixture(scope="module")
def server():
    executor = LangChainAgentExecutor(StubAgent("EVIDENCE"))
    app = build_a2a_app(_card(), executor)
    config = uvicorn.Config(app, host="127.0.0.1", port=PORT, log_level="error")
    srv = uvicorn.Server(config)
    thread = threading.Thread(target=srv.run, daemon=True)
    thread.start()
    for _ in range(50):
        if srv.started:
            break
        time.sleep(0.1)
    yield
    srv.should_exit = True
    thread.join(timeout=5)


async def test_round_trip(server):
    async with httpx.AsyncClient() as httpx_client:
        resolver = A2ACardResolver(httpx_client, URL)
        card = await resolver.get_agent_card()
        assert card.name == "StubAgent"
        factory = ClientFactory(ClientConfig(httpx_client=httpx_client, streaming=True))
        client = factory.create(card)
        req = SendMessageRequest(
            message=new_text_message("investigate payment-service", role=Role.ROLE_USER)
        )
        out = ""
        async for resp in client.send_message(req):
            out += get_stream_response_text(resp)
        assert "EVIDENCE" in out
        assert "investigate payment-service" in out
