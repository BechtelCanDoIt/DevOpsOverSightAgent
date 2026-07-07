"""A2A delegate tools — how the orchestrator reaches the specialist agents.

DataDogAgent and SplunkAgent are separate processes reached over A2A (JSON-RPC).
At startup the orchestrator resolves each AgentCard (with retry, so start order
is forgiving) and builds a client. The two @tool functions below are what the
LLM calls; each sends the request as an A2A message and returns the specialist's
final text. This is the "A2A at the platform-team boundary" the design calls
for — the orchestrator remains the single reasoning context that fuses the
evidence the two specialists return.
"""

from __future__ import annotations

import asyncio
import logging

from a2a.client.card_resolver import A2ACardResolver
from a2a.client.client_factory import ClientConfig, ClientFactory
from a2a.helpers.proto_helpers import get_stream_response_text, new_text_message
from a2a.types import Role, SendMessageRequest
from langchain_core.tools import tool

from oversight_common.config import env_or

logger = logging.getLogger("oversight")

# Set at startup by init_a2a_clients(); keyed "datadog"/"splunk".
_clients: dict[str, object] = {}


async def _resolve_card_with_retry(httpx_client, url: str, retries: int = 10, delay_s: float = 2.0):
    last_err: BaseException | None = None
    resolver = A2ACardResolver(httpx_client, url)
    for attempt in range(retries):
        try:
            return await resolver.get_agent_card()
        except Exception as e:  # noqa: BLE001 — sub-agent may still be booting
            last_err = e
            if attempt < retries - 1:
                await asyncio.sleep(delay_s)
    raise RuntimeError(f"could not resolve A2A card at {url}: {last_err}")


async def init_a2a_clients(httpx_client) -> None:
    """Resolve both specialist cards and build A2A clients over one shared httpx
    client (whose timeout enforces the A2A rung of the Timeout Chain)."""
    factory = ClientFactory(ClientConfig(httpx_client=httpx_client, streaming=True))
    for key, env_name, default in [
        ("datadog", "DATADOG_AGENT_URL", "http://datadog-agent:8101"),
        ("splunk", "SPLUNK_AGENT_URL", "http://splunk-agent:8102"),
    ]:
        url = env_or(env_name, default)
        card = await _resolve_card_with_retry(httpx_client, url)
        _clients[key] = factory.create(card)
        logger.info("resolved A2A client for %s at %s (%s)", key, url, card.name)


async def _ask(key: str, request: str) -> str:
    client = _clients.get(key)
    if client is None:
        return f"{key} agent is unavailable (A2A client not initialized)"
    req = SendMessageRequest(message=new_text_message(request, role=Role.ROLE_USER))
    out = ""
    async for resp in client.send_message(req):
        out += get_stream_response_text(resp)
    return out or f"(no response from {key} agent)"


@tool
async def ask_datadog_agent(request: str) -> str:
    """Delegate to the Datadog platform agent. It can search monitors, fetch
    metric series (error rate, latency), fetch APM traces/spans, search
    error-tracking issues, and search Datadog logs. Describe the service and the
    evidence you need; ask it to include any trace_id it finds."""
    return await _ask("datadog", request)


@tool
async def ask_splunk_agent(request: str) -> str:
    """Delegate to the Splunk platform agent. It runs SPL queries, lists indexes
    and saved searches, and explains queries. Give it a trace_id or an SPL query
    and ask it to summarize the matching log events."""
    return await _ask("splunk", request)


A2A_DELEGATE_TOOLS = [ask_datadog_agent, ask_splunk_agent]
