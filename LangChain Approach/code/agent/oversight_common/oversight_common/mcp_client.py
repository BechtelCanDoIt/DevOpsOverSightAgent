"""Base MCP client — the shared machinery behind DataDogMCPClient /
SplunkMCPClient.

Each concrete client wraps ``langchain_mcp_adapters.MultiServerMCPClient`` for a
single named backend over streamable HTTP. The ``headers`` hook is the future
live-vendor swap point (Datadog's remote MCP needs API/APP-key headers; Splunk
Cloud needs a bearer token). Tools are loaded eagerly at sub-agent startup with
retry/backoff so a still-starting mock does not crash the agent.
"""

from __future__ import annotations

import asyncio
import logging

from langchain_core.tools import BaseTool
from langchain_mcp_adapters.client import MultiServerMCPClient

logger = logging.getLogger("oversight")


class BaseMcpClient:
    """Thin, named MCP client for one backend (mock or live)."""

    #: subclasses set this — the MultiServerMCPClient connection key
    server_name: str = "mcp"

    def __init__(self, url: str, headers: dict[str, str] | None = None, timeout_s: int = 30):
        self.url = url
        self._client = MultiServerMCPClient(
            {
                self.server_name: {
                    "transport": "streamable_http",
                    "url": url,
                    "headers": headers or {},
                }
            }
        )
        self._timeout_s = timeout_s

    async def load_tools(self, retries: int = 10, delay_s: float = 2.0) -> list[BaseTool]:
        """Fetch the backend's tools as LangChain tools, retrying while the
        server is still coming up."""
        last_err: BaseException | None = None
        for attempt in range(retries):
            try:
                tools = await self._client.get_tools()
                logger.info("loaded %d tools from %s MCP at %s",
                            len(tools), self.server_name, self.url)
                return tools
            except Exception as e:  # noqa: BLE001 — startup race with the mock server
                last_err = e
                if attempt < retries - 1:
                    await asyncio.sleep(delay_s)
        raise RuntimeError(
            f"could not load tools from {self.server_name} MCP at {self.url}: {last_err}"
        )
