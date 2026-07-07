"""SplunkAgent tests: named MCP client wiring + card/skill shape."""

from __future__ import annotations

from splunk_agent.mcp_client import SplunkMCPClient
from splunk_agent.__main__ import SKILL, SERVICE_NAME


def test_client_default_url(monkeypatch):
    monkeypatch.delenv("SPLUNK_MCP_URL", raising=False)
    monkeypatch.delenv("SPLUNK_MCP_TOKEN", raising=False)
    client = SplunkMCPClient()
    assert client.url == "http://splunk-mock-mcp:8400/mcp"
    assert client.server_name == "splunk"


def test_client_bearer_from_token(monkeypatch):
    monkeypatch.setenv("SPLUNK_MCP_TOKEN", "s3cr3t")
    client = SplunkMCPClient()
    conns = client._client.connections
    assert conns["splunk"]["headers"] == {"Authorization": "Bearer s3cr3t"}


def test_skill_shape():
    assert SKILL.id == "splunk_log_search"
    assert "spl" in SKILL.tags
    assert SKILL.examples


def test_service_name():
    assert SERVICE_NAME == "splunk-agent"
