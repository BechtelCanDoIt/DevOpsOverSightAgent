"""DevOpsOverSightAgent — the orchestrator's FastAPI surface.

Endpoint contract matches the Ballerina agent byte-for-byte:
  GET  /health          -> {"status":"UP","service":"devops-oversight-agent"}
  POST /chat            {message, sessionId?, conversationId?} -> {"message": text}
  POST /investigate     {service, severity, description, id}   -> {status, alert_id, summary, sessionId}
  POST /webhook/alert   (Datadog-style, title fallback)        -> {status, summary, sessionId}

Investigations that end in a runbook proposal return the proposal text plus the
sessionId; the operator approves by POSTing {message:"approve", sessionId} to
/chat, which resumes the paused graph (the hard propose-before-act gate).

Run: python -m devops_oversight_agent.main
"""

from __future__ import annotations

import logging
import uuid
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI
from pydantic import BaseModel

from oversight_common.config import a2a_timeout_s, assert_timeout_chain, env_or, uvicorn_timeout_s
from oversight_common.llm_factory import check_llm_ready, make_llm
from oversight_common.otel import instrument_fastapi, setup_otel

from .a2a_clients import init_a2a_clients
from .agent import build_orchestrator, run_turn
from .prompts import build_investigation_prompt

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("oversight")

SERVICE_NAME = "devops-oversight-agent"


class ChatRequest(BaseModel):
    message: str
    sessionId: str | None = None
    conversationId: str | None = None


class InvestigateRequest(BaseModel):
    service: str
    severity: str = "P2"
    description: str = "Incident detected"
    id: str = "AGENT-001"


class WebhookAlert(BaseModel):
    service: str | None = None
    severity: str | None = None
    description: str | None = None
    title: str | None = None
    id: str | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    setup_otel(SERVICE_NAME)
    assert_timeout_chain()  # fail fast if the Timeout Chain is misordered
    check_llm_ready()
    # One shared httpx client whose timeout enforces the A2A rung of the chain.
    app.state.httpx = httpx.AsyncClient(timeout=a2a_timeout_s())
    try:
        await init_a2a_clients(app.state.httpx)
    except Exception as e:  # noqa: BLE001 — keep /health up if a sub-agent is late
        logger.error("A2A client init failed at startup (will error per-request): %s", e)
    app.state.agent = build_orchestrator(make_llm())
    yield
    await app.state.httpx.aclose()


app = FastAPI(title="devops-oversight-agent", lifespan=lifespan)
instrument_fastapi(app)


@app.get("/health")
async def health():
    return {"status": "UP", "service": SERVICE_NAME}


@app.post("/chat")
async def chat(req: ChatRequest):
    session_id = req.sessionId or req.conversationId or "default"
    result = await run_turn(app.state.agent, req.message, session_id)
    return {"message": result["text"]}


async def _investigate(service: str, severity: str, description: str, alert_id: str) -> dict:
    session_id = f"inv-{uuid.uuid4()}"
    prompt = build_investigation_prompt(service, severity, description, alert_id)
    result = await run_turn(app.state.agent, prompt, session_id)
    summary = result["text"]
    if result["status"] == "proposal":
        summary = f"{summary}\n\nApprove via POST /chat {{'message':'approve','sessionId':'{session_id}'}}"
    return {"status": "investigated", "alert_id": alert_id, "summary": summary, "sessionId": session_id}


@app.post("/investigate")
async def investigate(req: InvestigateRequest):
    return await _investigate(req.service, req.severity, req.description, req.id)


@app.post("/webhook/alert")
async def webhook_alert(alert: WebhookAlert):
    service = alert.service or "unknown-service"
    severity = alert.severity or "P2"
    description = alert.description or alert.title or "Datadog alert"
    alert_id = alert.id or f"DD-{uuid.uuid4().hex[:8]}"
    result = await _investigate(service, severity, description, alert_id)
    return {"status": result["status"], "summary": result["summary"], "sessionId": result["sessionId"]}


def main() -> None:
    import uvicorn

    port = int(env_or("AGENT_PORT", "8000"))
    uvicorn.run(app, host="0.0.0.0", port=port, log_level="warning", timeout_keep_alive=uvicorn_timeout_s())


if __name__ == "__main__":
    main()
