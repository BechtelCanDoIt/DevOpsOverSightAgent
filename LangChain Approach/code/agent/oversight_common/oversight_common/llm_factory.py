"""Provider-swappable LLM factory — port of the Ballerina llm_client.bal contract.

Identical env contract; the only thing that changes between providers is the
env var. Per-agent overrides are supported via a prefix, e.g.
``make_llm("DATADOG_AGENT")`` consults DATADOG_AGENT_LLM_PROVIDER (etc.) first,
falling back to the shared vars.

| LLM_PROVIDER | class        | env                                                     |
|--------------|--------------|---------------------------------------------------------|
| anthropic    | ChatAnthropic| ANTHROPIC_API_KEY (required), AGENT_MODEL, ANTHROPIC_URL |
| ollama       | ChatOllama   | OLLAMA_BASE_URL, OLLAMA_MODEL (creds-free)               |
| openai       | ChatOpenAI   | OPENAI_API_KEY (required), OPENAI_BASE_URL, OPENAI_MODEL |
| amp          | ChatOpenAI   | LLM_BASE_URL (AMP-injected, required), LLM_API_KEY, LLM_MODEL |
"""

from __future__ import annotations

import logging
import os

import httpx

from .config import env_or, llm_timeout_s

logger = logging.getLogger("oversight")

DEFAULT_ANTHROPIC_MODEL = "claude-sonnet-4-6"  # parity with the Ballerina stack
DEFAULT_OLLAMA_MODEL = "qwen3.5:9b"
DEFAULT_OLLAMA_URL = "http://host.docker.internal:11434"
DEFAULT_OPENAI_MODEL = "gpt-4o"
DEFAULT_OPENAI_URL = "https://api.openai.com"
DEFAULT_AMP_MODEL = "gpt-4o"


def _env(name: str, fallback: str, prefix: str | None) -> str:
    if prefix:
        v = os.environ.get(f"{prefix}_{name}", "")
        if v != "":
            return v
    return env_or(name, fallback)


def provider(prefix: str | None = None) -> str:
    return _env("LLM_PROVIDER", "anthropic", prefix).lower()


def make_llm(prefix: str | None = None):
    """Build the configured LangChain chat model. No sampling params are set —
    parity with the Ballerina agent, and Claude Opus 4.7+ rejects them anyway."""
    p = provider(prefix)
    timeout = llm_timeout_s()

    if p == "anthropic":
        from langchain_anthropic import ChatAnthropic

        kwargs: dict = {
            "model": _env("AGENT_MODEL", DEFAULT_ANTHROPIC_MODEL, prefix),
            "max_tokens": int(_env("LLM_MAX_TOKENS", "4096", prefix)),
            "timeout": timeout,
        }
        base_url = _env("ANTHROPIC_URL", "", prefix)  # AMP AI-gateway injection point
        if base_url:
            kwargs["base_url"] = base_url
        return ChatAnthropic(**kwargs)

    if p == "ollama":
        from langchain_ollama import ChatOllama

        return ChatOllama(
            model=_env("OLLAMA_MODEL", DEFAULT_OLLAMA_MODEL, prefix),
            base_url=_env("OLLAMA_BASE_URL", DEFAULT_OLLAMA_URL, prefix),
        )

    if p == "openai":
        from langchain_openai import ChatOpenAI

        base = _env("OPENAI_BASE_URL", DEFAULT_OPENAI_URL, prefix).rstrip("/")
        if not base.endswith("/v1"):
            base = f"{base}/v1"
        return ChatOpenAI(
            model=_env("OPENAI_MODEL", DEFAULT_OPENAI_MODEL, prefix),
            base_url=base,
            timeout=timeout,
        )

    if p == "amp":
        from langchain_openai import ChatOpenAI

        base_url = _env("LLM_BASE_URL", "", prefix)
        if not base_url:
            raise RuntimeError("LLM_PROVIDER=amp requires LLM_BASE_URL (injected by WSO2 AMP)")
        return ChatOpenAI(
            model=_env("LLM_MODEL", DEFAULT_AMP_MODEL, prefix),
            base_url=base_url,
            api_key=_env("LLM_API_KEY", "not-needed", prefix),
            timeout=timeout,
        )

    raise RuntimeError(f"Unknown LLM_PROVIDER '{p}' (expected anthropic|ollama|openai|amp)")


def check_llm_ready(prefix: str | None = None) -> bool:
    """Startup probe — logs loudly but never raises, so /health stays reachable
    (parity with the Ballerina agent's init behavior). For Ollama it also
    auto-pulls a missing model, matching the Ballerina agent."""
    p = provider(prefix)
    try:
        if p == "anthropic":
            if not os.environ.get("ANTHROPIC_API_KEY") and not _env("ANTHROPIC_URL", "", prefix):
                logger.error("LLM not ready: LLM_PROVIDER=anthropic but ANTHROPIC_API_KEY is unset")
                return False
            return True
        if p == "openai":
            if not os.environ.get("OPENAI_API_KEY"):
                logger.error("LLM not ready: LLM_PROVIDER=openai but OPENAI_API_KEY is unset")
                return False
            return True
        if p == "amp":
            if not _env("LLM_BASE_URL", "", prefix):
                logger.error("LLM not ready: LLM_PROVIDER=amp but LLM_BASE_URL is unset")
                return False
            return True
        if p == "ollama":
            base = _env("OLLAMA_BASE_URL", DEFAULT_OLLAMA_URL, prefix)
            model = _env("OLLAMA_MODEL", DEFAULT_OLLAMA_MODEL, prefix)
            with httpx.Client(timeout=10) as client:
                resp = client.get(f"{base}/api/tags")
                resp.raise_for_status()
                names = [m.get("name", "") for m in resp.json().get("models", [])]
                if not any(n == model or n.startswith(f"{model.split(':')[0]}:") for n in names):
                    logger.warning("Ollama model %s missing — pulling (this can take a while)", model)
                    client.post(f"{base}/api/pull", json={"model": model}, timeout=600)
            return True
    except Exception as exc:  # noqa: BLE001 — readiness must never crash the agent
        logger.error("LLM readiness probe failed for provider=%s: %s", p, exc)
        return False
    logger.error("LLM not ready: unknown provider %s", p)
    return False
