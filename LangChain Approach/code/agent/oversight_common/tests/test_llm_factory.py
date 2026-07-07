import pytest

from oversight_common.llm_factory import check_llm_ready, make_llm, provider


@pytest.fixture(autouse=True)
def clean_env(monkeypatch):
    for var in ("LLM_PROVIDER", "ANTHROPIC_API_KEY", "ANTHROPIC_URL", "AGENT_MODEL",
                "OLLAMA_BASE_URL", "OLLAMA_MODEL", "OPENAI_API_KEY", "OPENAI_BASE_URL",
                "OPENAI_MODEL", "LLM_BASE_URL", "LLM_API_KEY", "LLM_MODEL",
                "DATADOG_AGENT_LLM_PROVIDER", "DATADOG_AGENT_OLLAMA_MODEL"):
        monkeypatch.delenv(var, raising=False)


def test_default_provider_is_anthropic():
    assert provider() == "anthropic"


def test_anthropic_default_model(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-test")
    llm = make_llm()
    assert type(llm).__name__ == "ChatAnthropic"
    assert llm.model == "claude-sonnet-4-6"


def test_anthropic_amp_gateway_url(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-test")
    monkeypatch.setenv("ANTHROPIC_URL", "http://amp-gateway:9000")
    monkeypatch.setenv("AGENT_MODEL", "claude-opus-4-8")
    llm = make_llm()
    assert llm.model == "claude-opus-4-8"
    assert "amp-gateway" in str(llm.anthropic_api_url)


def test_ollama_defaults(monkeypatch):
    monkeypatch.setenv("LLM_PROVIDER", "ollama")
    llm = make_llm()
    assert type(llm).__name__ == "ChatOllama"
    assert llm.model == "qwen3.5:9b"
    assert llm.base_url == "http://host.docker.internal:11434"


def test_openai_appends_v1(monkeypatch):
    monkeypatch.setenv("LLM_PROVIDER", "openai")
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
    llm = make_llm()
    assert type(llm).__name__ == "ChatOpenAI"
    assert str(llm.openai_api_base).endswith("/v1")


def test_amp_requires_base_url(monkeypatch):
    monkeypatch.setenv("LLM_PROVIDER", "amp")
    with pytest.raises(RuntimeError, match="LLM_BASE_URL"):
        make_llm()


def test_amp_uses_openai_compat(monkeypatch):
    monkeypatch.setenv("LLM_PROVIDER", "amp")
    monkeypatch.setenv("LLM_BASE_URL", "http://amp:9000/llm")
    monkeypatch.setenv("LLM_MODEL", "gpt-4o-mini")
    llm = make_llm()
    assert type(llm).__name__ == "ChatOpenAI"
    assert llm.model_name == "gpt-4o-mini"


def test_unknown_provider_raises(monkeypatch):
    monkeypatch.setenv("LLM_PROVIDER", "bogus")
    with pytest.raises(RuntimeError, match="Unknown LLM_PROVIDER"):
        make_llm()


def test_prefix_override_wins(monkeypatch):
    monkeypatch.setenv("LLM_PROVIDER", "amp")
    monkeypatch.setenv("DATADOG_AGENT_LLM_PROVIDER", "ollama")
    monkeypatch.setenv("DATADOG_AGENT_OLLAMA_MODEL", "llama3.2:3b")
    llm = make_llm("DATADOG_AGENT")
    assert type(llm).__name__ == "ChatOllama"
    assert llm.model == "llama3.2:3b"


def test_check_llm_ready_missing_key_is_false_not_raise(monkeypatch):
    monkeypatch.setenv("LLM_PROVIDER", "anthropic")
    assert check_llm_ready() is False
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-test")
    assert check_llm_ready() is True
