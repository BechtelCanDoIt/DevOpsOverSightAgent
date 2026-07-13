// Activates observability exporters (imported for side effects only):
//   ballerinax/jaeger     -> OTLP gRPC trace export to the otel-collector (default)
//   ballerinax/prometheus -> Prometheus metrics endpoint scraped by the collector
//   ballerinax/amp        -> OTLP HTTP trace export straight to WSO2 AMP's
//                            observability gateway (its Traces view: LLM spans
//                            w/ token counts, tool spans w/ inputs/outputs)
// Which tracing exporter is ACTIVE is chosen by [ballerina.observe].tracingProvider
// in Config.toml ("jaeger" or "amp") — importing both just makes both available;
// only one runs at a time. Endpoints/toggles: [ballerina.observe],
// [ballerinax.jaeger], [ballerinax.amp].
import ballerinax/jaeger as _;
import ballerinax/prometheus as _;
import ballerinax/amp as _;
