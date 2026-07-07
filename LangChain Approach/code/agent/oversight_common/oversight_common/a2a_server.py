"""Shared A2A server machinery for the specialist sub-agents.

Wraps a compiled LangChain agent as an a2a-sdk ``AgentExecutor`` and mounts the
A2A JSON-RPC + agent-card routes on a Starlette app. Both DataDogAgent and
SplunkAgent are read-only investigators with the same request/response shape,
so this lives here rather than being copy-pasted twice.

The executor enqueues the agent's final text as a single A2A agent Message
(request/response; no long-running Task lifecycle needed) — matching the
message shape the orchestrator's A2A client reads back.
"""

from __future__ import annotations

import logging

import uvicorn
from a2a.helpers.proto_helpers import new_text_message, new_text_part
from a2a.server.agent_execution import AgentExecutor
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.routes import create_agent_card_routes, create_jsonrpc_routes
from a2a.server.tasks import InMemoryTaskStore
from a2a.types import (
    AgentCapabilities,
    AgentCard,
    AgentInterface,
    AgentSkill,
    Role,
)
from a2a.utils import DEFAULT_RPC_URL, TransportProtocol
from langchain_core.messages import HumanMessage
from starlette.applications import Starlette

from .config import recursion_limit
from .token_csv import TokenCsvCallback

logger = logging.getLogger("oversight")


def build_agent_card(
    *, name: str, description: str, url: str, skill: AgentSkill, version: str = "1.0.0"
) -> AgentCard:
    return AgentCard(
        name=name,
        description=description,
        version=version,
        capabilities=AgentCapabilities(streaming=True),
        default_input_modes=["text/plain"],
        default_output_modes=["text/plain"],
        supported_interfaces=[
            AgentInterface(url=url, protocol_binding=TransportProtocol.JSONRPC)
        ],
        skills=[skill],
    )


class LangChainAgentExecutor(AgentExecutor):
    """Runs the wrapped LangChain agent per incoming A2A message."""

    def __init__(self, agent, csv_model_fallback: str = ""):
        self._agent = agent
        self._csv_model_fallback = csv_model_fallback

    async def execute(self, context, event_queue) -> None:
        request = context.get_user_input()
        config = {
            "recursion_limit": recursion_limit(),
            "callbacks": [TokenCsvCallback(model_fallback=self._csv_model_fallback)],
        }
        try:
            result = await self._agent.ainvoke({"messages": [HumanMessage(request)]}, config)
            text = _final_text(result)
        except Exception as e:  # noqa: BLE001 — surface as agent text, never crash the server
            logger.exception("sub-agent invocation failed")
            text = f"investigation error: {e}"
        await event_queue.enqueue_event(new_text_message(text, role=Role.ROLE_AGENT))

    async def cancel(self, context, event_queue) -> None:  # pragma: no cover
        raise NotImplementedError("cancellation is not supported")


def _final_text(result) -> str:
    messages = result.get("messages", []) if isinstance(result, dict) else []
    for msg in reversed(messages):
        content = getattr(msg, "content", None)
        if isinstance(content, str) and content.strip():
            return content
        if isinstance(content, list):  # some providers return content blocks
            parts = [b.get("text", "") for b in content if isinstance(b, dict)]
            joined = "".join(parts).strip()
            if joined:
                return joined
    return "(no response)"


def build_a2a_app(card: AgentCard, executor: AgentExecutor) -> Starlette:
    handler = DefaultRequestHandler(
        agent_executor=executor,
        task_store=InMemoryTaskStore(),
        agent_card=card,
    )
    routes = create_agent_card_routes(card) + create_jsonrpc_routes(handler, rpc_url=DEFAULT_RPC_URL)
    return Starlette(routes=routes)


def run_a2a_agent(card: AgentCard, executor: AgentExecutor, host: str, port: int) -> None:
    app = build_a2a_app(card, executor)
    logger.info("starting %s (A2A JSON-RPC) on %s:%d", card.name, host, port)
    uvicorn.run(app, host=host, port=port, log_level="warning")
