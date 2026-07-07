"""In-memory audit log + deploy-freeze flag — ported from runbooks.bal state.

POC parity: this is in-memory and lost on restart (documented in
KNOWN_ISSUES). Production would persist to a remediation-MCP trust domain.
"""

from __future__ import annotations

_audit_log: list[str] = []
_deploy_frozen = False
_deploy_freeze_reason = ""


def append_audit(entry: str) -> None:
    _audit_log.append(entry)


def get_audit_log() -> list[str]:
    return list(_audit_log)


def set_deploy_freeze(frozen: bool, reason: str = "") -> None:
    global _deploy_frozen, _deploy_freeze_reason
    _deploy_frozen = frozen
    _deploy_freeze_reason = reason


def is_deploy_frozen() -> bool:
    return _deploy_frozen


def deploy_freeze_reason() -> str:
    return _deploy_freeze_reason


def reset_for_tests() -> None:
    global _deploy_frozen, _deploy_freeze_reason
    _audit_log.clear()
    _deploy_frozen = False
    _deploy_freeze_reason = ""
