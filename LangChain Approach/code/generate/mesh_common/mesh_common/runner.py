"""Dual-listener runner — replicates the Ballerina per-service process layout.

Every mesh service runs two HTTP listeners in one process: the business app on
:9090 and the chaos app on :9099, so the compose port contract
(1909x:9090 / 1919x:9099) matches the Ballerina stack exactly.
"""

from __future__ import annotations

import asyncio
import signal

import uvicorn

from .chaos import ChaosState, build_chaos_app
from .obs import env_or, setup_logging
from .telemetry import init_telemetry, instrument_app


def run(business_app, service_name: str, module_name: str, chaos_state: ChaosState,
        business_port: int | None = None, chaos_port: int | None = None) -> None:
    """Boot telemetry + logging, then serve business (:9090) and chaos (:9099)."""
    init_telemetry(service_name)
    setup_logging(module_name)
    instrument_app(business_app, service_name)

    business_port = business_port or int(env_or("BUSINESS_PORT", "9090"))
    chaos_port = chaos_port or int(env_or("CHAOS_PORT", "9099"))
    chaos_app = build_chaos_app(chaos_state)

    servers = [
        uvicorn.Server(uvicorn.Config(business_app, host="0.0.0.0", port=business_port,
                                      log_level="warning", timeout_graceful_shutdown=5)),
        uvicorn.Server(uvicorn.Config(chaos_app, host="0.0.0.0", port=chaos_port,
                                      log_level="warning", timeout_graceful_shutdown=5)),
    ]

    async def serve() -> None:
        loop = asyncio.get_running_loop()

        def stop() -> None:
            # One signal stops both listeners — otherwise the chaos listener
            # can outlive the business app across compose restarts.
            for server in servers:
                server.should_exit = True

        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, stop)
        await asyncio.gather(*(server.serve() for server in servers))

    asyncio.run(serve())
