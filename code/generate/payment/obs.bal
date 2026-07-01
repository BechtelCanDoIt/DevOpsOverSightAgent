import ballerina/log;
import ballerina/observe;
import ballerina/os;

// Read an env var, falling back to a default when unset/empty.
isolated function envOr(string name, string fallback) returns string {
    string v = os:getEnv(name);
    return v == "" ? fallback : v;
}

// Active OTel trace/span IDs (empty strings when outside a span).
isolated function spanCtx() returns [string, string] {
    map<string> c = observe:getSpanContext();
    return [c["traceId"] ?: "", c["spanId"] ?: ""];
}

// Common-case structured log: auto-injects trace_id/span_id so Splunk logs
// join to Datadog APM traces. For richer events call log:printInfo directly
// with trace_id/span_id plus domain fields.
isolated function logInfo(string msg) {
    [string, string] [tid, sid] = spanCtx();
    log:printInfo(msg, trace_id = tid, span_id = sid);
}

isolated function logError(string msg, error? e = ()) {
    [string, string] [tid, sid] = spanCtx();
    log:printError(msg, 'error = e, trace_id = tid, span_id = sid);
}
