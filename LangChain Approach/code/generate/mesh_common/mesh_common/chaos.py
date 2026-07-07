"""Chaos injection — behavioral port of the Ballerina chaos.bal seeded kit.

Contract (identical to the Ballerina mesh):
  POST /chaos/latency {ms, duration_s=60}
  POST /chaos/error   {rate, status=502, duration_s=60}
  POST /chaos/reset
All gated by the X-Chaos-Token header (403 on mismatch). Business handlers call
``apply_chaos(state)`` at entry: injected latency is applied first (async — a
blocking sleep here would stall every in-flight request on the event loop),
then the error probability check; a returned int is the HTTP status to fail
with, None means proceed normally. /health is never gated.
"""

from __future__ import annotations

import asyncio
import random
import time
from dataclasses import dataclass, field

from fastapi import FastAPI, Header
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel

from .obs import env_or


@dataclass
class ChaosState:
    latency_ms: int = 0
    latency_until: int = 0  # epoch seconds; window end (0 = off)
    error_rate: float = 0.0
    error_until: int = 0
    error_status: int = 502
    lock: asyncio.Lock = field(default_factory=asyncio.Lock, repr=False)


class LatencyReq(BaseModel):
    ms: int
    duration_s: int = 60


class ErrorReq(BaseModel):
    rate: float
    status: int = 502
    duration_s: int = 60


async def apply_chaos(state: ChaosState) -> int | None:
    """Apply injected latency, then probability-check an injected error.

    Returns the HTTP status to fail with, or None to proceed. Same ordering as
    the Ballerina kit so a request can be both delayed and failed.
    """
    now = int(time.time())
    async with state.lock:
        lat = state.latency_ms
        lat_until = state.latency_until
        rate = state.error_rate
        err_until = state.error_until
        status = state.error_status
    if lat_until > now and lat > 0:
        await asyncio.sleep(lat / 1000)
    if err_until > now and rate > 0.0 and random.random() < rate:
        return status
    return None


def chaos_error_response(status: int) -> JSONResponse:
    return JSONResponse(status_code=status, content={"error": "chaos-injected", "status": status})


def build_chaos_app(state: ChaosState, token: str | None = None) -> FastAPI:
    """The :9099 chaos listener, one per service process."""
    chaos_token = token if token is not None else env_or("CHAOS_TOKEN", "dev-chaos-token")
    app = FastAPI(title="chaos", docs_url=None, redoc_url=None, openapi_url=None)

    def authed(header_token: str | None) -> bool:
        return header_token == chaos_token

    @app.post("/chaos/latency")
    async def latency(req: LatencyReq, x_chaos_token: str | None = Header(default=None)):
        if not authed(x_chaos_token):
            return Response(status_code=403)
        now = int(time.time())
        async with state.lock:
            state.latency_ms = req.ms
            state.latency_until = now + req.duration_s
        return {"status": "latency injected", "ms": req.ms, "duration_s": req.duration_s}

    @app.post("/chaos/error")
    async def error(req: ErrorReq, x_chaos_token: str | None = Header(default=None)):
        if not authed(x_chaos_token):
            return Response(status_code=403)
        now = int(time.time())
        async with state.lock:
            state.error_rate = req.rate
            state.error_status = req.status
            state.error_until = now + req.duration_s
        return {"status": "error injected", "rate": req.rate, "errorStatus": req.status}

    @app.post("/chaos/reset")
    async def reset(x_chaos_token: str | None = Header(default=None)):
        if not authed(x_chaos_token):
            return Response(status_code=403)
        async with state.lock:
            state.latency_ms = 0
            state.latency_until = 0
            state.error_rate = 0.0
            state.error_until = 0
        return {"status": "reset"}

    return app
