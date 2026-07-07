"""traceparent build/parse tests — mirrors the Ballerina parseTraceparent coverage."""

from mesh_common.w3c import build_traceparent, parse_traceparent

TID = "abc123def456789012345678deadbeef"
SID = "00f067aa0ba902b7"


def test_build_traceparent():
    assert build_traceparent(TID, SID) == f"00-{TID}-{SID}-01"


def test_roundtrip():
    assert parse_traceparent(build_traceparent(TID, SID)) == (TID, SID)


def test_rejects_wrong_part_count():
    assert parse_traceparent(f"00-{TID}-{SID}") == ("", "")
    assert parse_traceparent(f"00-{TID}-{SID}-01-extra") == ("", "")
    assert parse_traceparent("") == ("", "")


def test_rejects_wrong_version():
    assert parse_traceparent(f"01-{TID}-{SID}-01") == ("", "")


def test_rejects_bad_trace_id():
    assert parse_traceparent(f"00-{TID[:-1]}-{SID}-01") == ("", "")     # 31 hex
    assert parse_traceparent(f"00-{TID.upper()}-{SID}-01") == ("", "")  # uppercase
    assert parse_traceparent(f"00-{'z' * 32}-{SID}-01") == ("", "")     # non-hex


def test_rejects_bad_span_id():
    assert parse_traceparent(f"00-{TID}-{SID[:-1]}-01") == ("", "")
    assert parse_traceparent(f"00-{TID}-{'g' * 16}-01") == ("", "")
