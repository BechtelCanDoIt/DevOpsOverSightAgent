import pytest

from oversight_common import config


def test_max_turns_default_and_override(monkeypatch):
    monkeypatch.delenv("MAX_TURNS", raising=False)
    assert config.max_turns() == 30
    assert config.recursion_limit() == 61
    monkeypatch.setenv("MAX_TURNS", "25")
    assert config.max_turns() == 25
    assert config.recursion_limit() == 51


def test_timeout_chain_defaults_ordered(monkeypatch):
    for var in ("UVICORN_TIMEOUT_S", "A2A_TIMEOUT_S", "LLM_TIMEOUT_S", "MCP_TIMEOUT_S"):
        monkeypatch.delenv(var, raising=False)
    config.assert_timeout_chain()  # must not raise
    assert config.uvicorn_timeout_s() > config.a2a_timeout_s() > config.llm_timeout_s() > config.mcp_timeout_s()


def test_timeout_chain_violation_raises(monkeypatch):
    monkeypatch.setenv("A2A_TIMEOUT_S", "700")  # outlives uvicorn's 600
    with pytest.raises(RuntimeError, match="Timeout Chain violated"):
        config.assert_timeout_chain()


def test_env_or_empty_falls_back(monkeypatch):
    monkeypatch.setenv("SOME_VAR", "")
    assert config.env_or("SOME_VAR", "dflt") == "dflt"
