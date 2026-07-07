"""DataDogMCPClient — the named MCP client the architecture calls for.

Wraps the shared BaseMcpClient for the Datadog MCP backend (mock during dev,
mcp.datadoghq.com in production via SPLUNK/DATADOG_MCP_URL + auth headers).
"""

from __future__ import annotations

import os

from oversight_common.config import env_or, mcp_timeout_s
from oversight_common.mcp_client import BaseMcpClient


class DataDogMCPClient(BaseMcpClient):
    server_name = "datadog"

    def __init__(self, url: str | None = None, headers: dict[str, str] | None = None):
        url = url or env_or("DATADOG_MCP_URL", "http://datadog-mock-mcp:8401/mcp")
        # Live-vendor swap hook: DATADOG_MCP_HEADERS is "k1=v1,k2=v2".
        if headers is None:
            raw = os.environ.get("DATADOG_MCP_HEADERS", "")
            headers = dict(
                pair.split("=", 1) for pair in raw.split(",") if "=" in pair
            ) or None
        super().__init__(url, headers, timeout_s=mcp_timeout_s())
