"""DataDogAgent tests: named MCP client wiring + card/skill shape."""

from __future__ import annotations

from datadog_agent.mcp_client import DataDogMCPClient
from datadog_agent.__main__ import SKILL, SERVICE_NAME


def test_client_default_url(monkeypatch):
    monkeypatch.delenv("DATADOG_MCP_URL", raising=False)
    monkeypatch.delenv("DATADOG_MCP_HEADERS", raising=False)
    client = DataDogMCPClient()
    assert client.url == "http://datadog-mock-mcp:8401/mcp"
    assert client.server_name == "datadog"


def test_client_url_override(monkeypatch):
    monkeypatch.setenv("DATADOG_MCP_URL", "https://mcp.datadoghq.com/mcp")
    client = DataDogMCPClient()
    assert client.url == "https://mcp.datadoghq.com/mcp"


def test_client_headers_from_env(monkeypatch):
    monkeypatch.setenv("DATADOG_MCP_HEADERS", "DD-API-KEY=k1,DD-APPLICATION-KEY=k2")
    client = DataDogMCPClient()
    conns = client._client.connections
    assert conns["datadog"]["headers"] == {"DD-API-KEY": "k1", "DD-APPLICATION-KEY": "k2"}


def test_skill_shape():
    assert SKILL.id == "datadog_evidence"
    assert "monitors" in SKILL.tags
    assert SKILL.examples  # examples guide the orchestrator's delegation


def test_service_name():
    assert SERVICE_NAME == "datadog-agent"
