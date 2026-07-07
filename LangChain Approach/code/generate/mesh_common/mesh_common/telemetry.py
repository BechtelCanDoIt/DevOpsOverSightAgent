"""OTel wiring — replaces the Ballerina tracing.bal side-effect imports.

Deliberate deviations from the Ballerina stack (documented in architecture.md):
metrics are OTLP-push (no Prometheus :9797 scrape, no servicename transform),
and logs ship through the OTLP logs pipeline (no filelog receiver).

Honors the standard OTel env vars set by the compose anchors:
OTEL_SERVICE_NAME, OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_RESOURCE_ATTRIBUTES.
Set OTEL_SDK_DISABLED=true (standard var) to skip all exporter setup — the
default for unit tests, so pytest runs collector-free.
"""

from __future__ import annotations

import logging
import time

from .obs import env_or

_initialized = False


def telemetry_enabled() -> bool:
    return env_or("OTEL_SDK_DISABLED", "false").lower() != "true"


def init_telemetry(service_name: str) -> None:
    """Set up tracing + metrics + log export and auto-instrumentation. Idempotent."""
    global _initialized
    if _initialized or not telemetry_enabled():
        return
    _initialized = True

    from opentelemetry import metrics, trace
    from opentelemetry._logs import set_logger_provider
    from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
    from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
    from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
    from opentelemetry.sdk.metrics import MeterProvider
    from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    # Resource.create merges OTEL_RESOURCE_ATTRIBUTES / OTEL_SERVICE_NAME from env.
    resource = Resource.create({"service.name": service_name})

    tracer_provider = TracerProvider(resource=resource)
    tracer_provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(tracer_provider)

    reader = PeriodicExportingMetricReader(OTLPMetricExporter())
    metrics.set_meter_provider(MeterProvider(resource=resource, metric_readers=[reader]))

    logger_provider = LoggerProvider(resource=resource)
    logger_provider.add_log_record_processor(BatchLogRecordProcessor(OTLPLogExporter()))
    set_logger_provider(logger_provider)
    logging.getLogger().addHandler(LoggingHandler(level=logging.INFO, logger_provider=logger_provider))

    # Client-side auto-instrumentation. httpx propagates W3C traceparent on
    # every outbound call — the HTTP legs of the mesh join traces automatically.
    from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor

    HTTPXClientInstrumentor().instrument()
    try:
        from opentelemetry.instrumentation.asyncpg import AsyncPGInstrumentor

        AsyncPGInstrumentor().instrument()
    except Exception:  # payment/notification have no DB; instrumentation is best-effort
        pass
    try:
        from opentelemetry.instrumentation.redis import RedisInstrumentor

        RedisInstrumentor().instrument()
    except Exception:
        pass


def instrument_app(app, service_name: str) -> None:
    """FastAPI server spans + the demo's request metrics on the business app.

    Emits `<svc>.request.duration` (ms histogram) and `<svc>.request.errors`
    (counter, 5xx only) — the metric names the Datadog mock's story references
    (e.g. payment.request.errors), so live-Datadog mode tells the same story.
    """
    if not telemetry_enabled():
        return

    from opentelemetry import metrics
    from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

    FastAPIInstrumentor.instrument_app(app)

    prefix = service_name.removesuffix("-service")
    meter = metrics.get_meter("mesh_common")
    errors = meter.create_counter(f"{prefix}.request.errors", description="5xx responses")
    duration = meter.create_histogram(f"{prefix}.request.duration", unit="ms")

    @app.middleware("http")
    async def _record_request_metrics(request, call_next):
        start = time.perf_counter()
        response = await call_next(request)
        elapsed_ms = (time.perf_counter() - start) * 1000
        attrs = {"http.route": request.url.path, "http.response.status_code": response.status_code}
        duration.record(elapsed_ms, attributes=attrs)
        if response.status_code >= 500:
            errors.add(1, attributes=attrs)
        return response
