from types import SimpleNamespace

import pytest

from oversight_common import token_csv
from oversight_common.token_csv import HEADER, TokenCsvCallback


@pytest.fixture(autouse=True)
def reset():
    token_csv.reset_for_tests()


def fake_response(input_tokens=100, output_tokens=20, model="qwen3.5:9b"):
    message = SimpleNamespace(
        usage_metadata={"input_tokens": input_tokens, "output_tokens": output_tokens,
                        "total_tokens": input_tokens + output_tokens},
        response_metadata={"model_name": model},
    )
    return SimpleNamespace(generations=[[SimpleNamespace(message=message)]], llm_output={})


def test_disabled_by_default(tmp_path, monkeypatch):
    monkeypatch.delenv("CSV_MCP_PROXY", raising=False)
    path = tmp_path / "tokens.csv"
    cb = TokenCsvCallback(path=str(path))
    cb.on_llm_end(fake_response())
    assert not path.exists()


def test_golden_row_shape(tmp_path):
    path = tmp_path / "tokens.csv"
    cb = TokenCsvCallback(path=str(path), enabled=True)
    cb.on_llm_end(fake_response(100, 20))
    cb.on_llm_end(fake_response(250, 40))
    lines = path.read_text().strip().splitlines()
    assert lines[0] == HEADER
    fields = lines[1].split(",")
    assert fields[1] == "qwen3.5:9b"
    assert fields[2:] == ["1", "100", "20", "120"]
    assert lines[2].split(",")[2:] == ["2", "250", "40", "290"]


def test_header_rewritten_once_per_process(tmp_path):
    path = tmp_path / "tokens.csv"
    first = TokenCsvCallback(path=str(path), enabled=True)
    first.on_llm_end(fake_response())
    second = TokenCsvCallback(path=str(path), enabled=True)  # new invocation, same process
    second.on_llm_end(fake_response())
    lines = path.read_text().strip().splitlines()
    assert lines.count(HEADER) == 1
    assert len(lines) == 3


def test_missing_usage_writes_zeros(tmp_path):
    path = tmp_path / "tokens.csv"
    cb = TokenCsvCallback(path=str(path), enabled=True, model_fallback="fallback-model")
    message = SimpleNamespace(usage_metadata=None, response_metadata={})
    cb.on_llm_end(SimpleNamespace(generations=[[SimpleNamespace(message=message)]], llm_output={}))
    fields = path.read_text().strip().splitlines()[1].split(",")
    assert fields[1] == "fallback-model"
    assert fields[3:] == ["0", "0", "0"]


def test_timing_column_opt_in(tmp_path, monkeypatch):
    monkeypatch.setenv("CSV_INCLUDE_TIMING", "TRUE")
    path = tmp_path / "tokens.csv"
    cb = TokenCsvCallback(path=str(path), enabled=True)
    cb.on_chat_model_start({}, [])
    cb.on_llm_end(fake_response())
    lines = path.read_text().strip().splitlines()
    assert lines[0] == HEADER + ",durationMs"
    assert len(lines[1].split(",")) == 7
