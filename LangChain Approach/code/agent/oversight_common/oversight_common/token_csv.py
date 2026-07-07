"""Per-turn token telemetry — port of appendOllamaTokenCsv (commit 8075b8c).

Identical CSV shape: header ``timestamp,model,turn,inputTokens,outputTokens,
totalTokens``; the header is rewritten once per process run, subsequent turns
append rows. Same env switches: enable with CSV_MCP_PROXY=TRUE, path via
CSV_MCP_PROXY_PATH (the names are kept verbatim for parity even though this
port has no MCP proxy).

Unlike the Ballerina original (Ollama-only), this reads LangChain's normalized
``usage_metadata``, so it works for ChatOllama (prompt_eval_count/eval_count),
ChatAnthropic, and OpenAI-compatible providers alike. An optional durationMs
column can be enabled with CSV_INCLUDE_TIMING=TRUE (off by default to keep the
file schema identical to the Ballerina stack's).
"""

from __future__ import annotations

import datetime
import time
from typing import Any

from langchain_core.callbacks import BaseCallbackHandler

from .config import env_or

HEADER = "timestamp,model,turn,inputTokens,outputTokens,totalTokens"
_initialized_paths: set[str] = set()


def _extract_usage(response: Any) -> tuple[int, int, int, str]:
    """Best-effort usage extraction across providers."""
    input_tokens = output_tokens = total_tokens = 0
    model = ""
    try:
        generation = response.generations[0][0]
        message = getattr(generation, "message", None)
        usage = getattr(message, "usage_metadata", None) if message is not None else None
        if usage:
            input_tokens = int(usage.get("input_tokens", 0) or 0)
            output_tokens = int(usage.get("output_tokens", 0) or 0)
            total_tokens = int(usage.get("total_tokens", input_tokens + output_tokens) or 0)
        meta = getattr(message, "response_metadata", None) if message is not None else None
        if meta:
            model = meta.get("model_name") or meta.get("model") or ""
    except (IndexError, AttributeError):
        pass
    if not model and getattr(response, "llm_output", None):
        model = response.llm_output.get("model_name") or response.llm_output.get("model") or ""
    return input_tokens, output_tokens, total_tokens, model


class TokenCsvCallback(BaseCallbackHandler):
    """Attach per agent invocation: callbacks=[TokenCsvCallback()]."""

    def __init__(self, path: str | None = None, enabled: bool | None = None, model_fallback: str = ""):
        self.enabled = (
            enabled if enabled is not None else env_or("CSV_MCP_PROXY", "FALSE").upper() == "TRUE"
        )
        self.path = path or env_or("CSV_MCP_PROXY_PATH", "ollama_tokens_mcp_proxy.csv")
        self.include_timing = env_or("CSV_INCLUDE_TIMING", "FALSE").upper() == "TRUE"
        self.model_fallback = model_fallback
        self.turn = 0
        self._turn_started: float | None = None

    def on_llm_start(self, serialized, prompts, **kwargs) -> None:
        self._turn_started = time.perf_counter()

    def on_chat_model_start(self, serialized, messages, **kwargs) -> None:
        self._turn_started = time.perf_counter()

    def on_llm_end(self, response, **kwargs) -> None:
        if not self.enabled:
            return
        self.turn += 1
        input_tokens, output_tokens, total_tokens, model = _extract_usage(response)
        model = model or self.model_fallback
        timestamp = datetime.datetime.now(tz=datetime.timezone.utc).isoformat()
        row = f"{timestamp},{model},{self.turn},{input_tokens},{output_tokens},{total_tokens}"
        header = HEADER
        if self.include_timing:
            duration_ms = 0 if self._turn_started is None else int((time.perf_counter() - self._turn_started) * 1000)
            row += f",{duration_ms}"
            header += ",durationMs"
        if self.path not in _initialized_paths:
            _initialized_paths.add(self.path)
            with open(self.path, "w") as f:
                f.write(header + "\n" + row + "\n")
        else:
            with open(self.path, "a") as f:
                f.write(row + "\n")


def reset_for_tests() -> None:
    _initialized_paths.clear()
