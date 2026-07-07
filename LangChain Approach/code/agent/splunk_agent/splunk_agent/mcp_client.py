"""SplunkMCPClient — the named MCP client the architecture calls for.

Wraps the shared BaseMcpClient for the Splunk MCP backend (mock during dev,
Splunk Cloud MCP in production via SPLUNK_MCP_URL + bearer auth).
"""

from __future__ import annotations

import os

from oversight_common.config import env_or, mcp_timeout_s
from oversight_common.mcp_client import BaseMcpClient


class SplunkMCPClient(BaseMcpClient):
    server_name = "splunk"

    def __init__(self, url: str | None = None, headers: dict[str, str] | None = None):
        url = url or env_or("SPLUNK_MCP_URL", "http://splunk-mock-mcp:8400/mcp")
        # Live-vendor swap hook: SPLUNK_MCP_TOKEN becomes a bearer header.
        if headers is None:
            token = os.environ.get("SPLUNK_MCP_TOKEN", "")
            headers = {"Authorization": f"Bearer {token}"} if token else None
        super().__init__(url, headers, timeout_s=mcp_timeout_s())
