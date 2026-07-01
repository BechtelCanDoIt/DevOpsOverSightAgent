// Activates observability exporters (imported for side effects only):
//   ballerinax/jaeger     -> OTLP gRPC trace export to the otel-collector
//   ballerinax/prometheus -> Prometheus metrics endpoint scraped by the collector
// So the generated load is itself visible in Datadog (architecture.md §3).
import ballerinax/jaeger as _;
import ballerinax/prometheus as _;
