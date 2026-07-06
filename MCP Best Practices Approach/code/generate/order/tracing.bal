// Activates observability exporters (imported for side effects only):
//   ballerinax/jaeger     -> OTLP gRPC trace export to the otel-collector
//   ballerinax/prometheus -> Prometheus metrics endpoint scraped by the collector
// Endpoints/toggles are configured in Config.toml ([ballerina.observe], [ballerinax.jaeger]).
import ballerinax/jaeger as _;
import ballerinax/prometheus as _;
