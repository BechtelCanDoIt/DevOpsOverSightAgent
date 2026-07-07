"""Agent-tier OTel setup — the agents observe themselves through the same
collector as the mesh (the agent investigates with the tools that observe it).

httpx instrumentation propagates W3C `traceparent` on every outbound call, so
one trace spans user → orchestrator → A2A → sub-agent → MCP → mock server.
Set OTEL_SDK_DISABLED=true (standard var) to skip setup — the default in tests.
"""

from __future__ import annotations

import logging

from .config import env_or

_initialized = False


def telemetry_enabled() -> bool:
    return env_or("OTEL_SDK_DISABLED", "false").lower() != "true"


def setup_otel(service_name: str) -> None:
    global _initialized
    if _initialized or not telemetry_enabled():
        return
    _initialized = True

    from opentelemetry import trace
    from opentelemetry._logs import set_logger_provider
    from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
    from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    resource = Resource.create({"service.name": service_name})
    tracer_provider = TracerProvider(resource=resource)
    tracer_provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(tracer_provider)

    logger_provider = LoggerProvider(resource=resource)
    logger_provider.add_log_record_processor(BatchLogRecordProcessor(OTLPLogExporter()))
    set_logger_provider(logger_provider)
    logging.getLogger().addHandler(LoggingHandler(level=logging.INFO, logger_provider=logger_provider))

    from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor

    HTTPXClientInstrumentor().instrument()


def instrument_fastapi(app) -> None:
    if not telemetry_enabled():
        return
    from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

    FastAPIInstrumentor.instrument_app(app)
