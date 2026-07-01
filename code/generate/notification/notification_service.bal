import ballerina/http;
import ballerina/lang.value;
import ballerina/log;

import ballerinax/nats;

// Shared HTTP listener. notification-service is an async consumer, so /health is
// the ONLY HTTP route — there are no business HTTP endpoints.
listener http:Listener mainListener = new (9090);

service /health on mainListener {
    resource function get .() returns json => {status: "UP", 'service: "notification-service"};
}

// Order event envelope published by order-service to subject `orders.created`.
// `traceparent` is W3C trace-context (NATS does not auto-propagate OTel context),
// carrying the order's trace so this async leg joins the same trace in Splunk.
type OrderEvent record {
    string orderId;
    string customerId;
    decimal total;
    string traceparent;
};

// Lowercase-hex check (W3C trace-context uses lowercase hex).
isolated function isLowerHex(string s) returns boolean {
    return s.length() > 0 && (re `^[0-9a-f]+$`.isFullMatch(s));
}

// Parse a W3C `traceparent` header of the form
//   00-<32-hex traceId>-<16-hex spanId>-<2-hex flags>
// Returns [traceId, spanId] on success, or ["", ""] when the envelope is
// malformed (wrong version, wrong field count, wrong hex length, non-hex chars).
// Kept as a pure function so it can be unit-tested without NATS.
isolated function parseTraceparent(string tp) returns [string, string] {
    string[] parts = re `-`.split(tp);
    if parts.length() != 4 {
        return ["", ""];
    }
    if parts[0] != "00" {
        return ["", ""];
    }
    if parts[1].length() != 32 || parts[2].length() != 16 {
        return ["", ""];
    }
    if !isLowerHex(parts[1]) || !isLowerHex(parts[2]) {
        return ["", ""];
    }
    return [parts[1], parts[2]];
}

// NATS consumer defined as a service object so init() can attach it to a
// dynamically-created listener — prevents a connection failure from crashing
// the module when NATS is unavailable (e.g. during unit tests).
// Subject "orders.created" is passed to Listener.attach() rather than via
// @nats:ServiceConfig because that annotation is not allowed on variables.
final nats:Service orderConsumer = service object {

    remote function onMessage(nats:BytesMessage message) {
        _ = applyChaos();

        string raw = "";
        do {
            raw = check string:fromBytes(message.content);
            json payload = check value:fromJsonString(raw);
            OrderEvent event = check payload.cloneWithType(OrderEvent);

            [string, string] [tid, sid] = parseTraceparent(event.traceparent);
            if tid == "" {
                logError(string `bad traceparent in order event: ${event.traceparent}`);
                return;
            }

            log:printInfo("notification sent", trace_id = tid, span_id = sid, order_id = event.orderId);
        } on fail error e {
            logError(string `failed to process order event: ${raw}`, e);
        }
    }
};

// Start the NATS consumer inside init() so a connection failure degrades
// gracefully rather than aborting module load.
function init() {
    do {
        nats:Listener natsListener = check new (envOr("NATS_URL", "nats://nats:4222"));
        check natsListener.attach(orderConsumer, "orders.created");
        check natsListener.'start();
    } on fail var e {
        log:printWarn("NATS broker unreachable — order event consumer not started", 'error = e);
    }
}
