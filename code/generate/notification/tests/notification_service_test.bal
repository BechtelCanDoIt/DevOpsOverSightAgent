// Unit tests for notification-service.
//
// Covered:
//   - envOr (fallback path + override path)
//   - chaosAuthed (matching + non-matching token)
//   - chaosErrorResponse (status echoed on response + JSON payload)
//   - parseTraceparent (valid + every malformed variant called out in CONVENTIONS.md)
//
// These tests are pure — they do NOT require a running NATS broker, Postgres,
// or chaos HTTP listener. The NATS @ServiceConfig subscriber and the :9099
// chaos HTTP listener boot as side-effects when the module loads, but tests
// here exercise only the pure helpers.
import ballerina/http;
import ballerina/os;
import ballerina/test;

// ---------- envOr ----------

@test:Config {}
function testEnvOrReturnsFallbackWhenUnset() {
    // A name that should not exist in the test env.
    string val = envOr("NOTIFICATION_TEST_UNSET_VAR_XYZ", "fallback-value");
    test:assertEquals(val, "fallback-value");
}

@test:Config {}
function testEnvOrReturnsValueWhenSet() returns error? {
    check os:setEnv("NOTIFICATION_TEST_SET_VAR", "real-value");
    string val = envOr("NOTIFICATION_TEST_SET_VAR", "fallback-value");
    test:assertEquals(val, "real-value");
    // Clean up so we don't leak into other tests.
    check os:unsetEnv("NOTIFICATION_TEST_SET_VAR");
}

// ---------- chaosAuthed ----------

@test:Config {}
function testChaosAuthedAcceptsMatchingToken() {
    // Use the module-level `chaosToken` directly so the test stays correct
    // regardless of whether CHAOS_TOKEN happens to be exported in the test env.
    test:assertTrue(chaosAuthed(chaosToken));
}

@test:Config {}
function testChaosAuthedRejectsBadAndMissingToken() {
    test:assertFalse(chaosAuthed("definitely-not-the-token-" + chaosToken));
    test:assertFalse(chaosAuthed(()));
    test:assertFalse(chaosAuthed(""));
}

// ---------- chaosErrorResponse ----------

@test:Config {}
function testChaosErrorResponseStatusAndPayload() returns error? {
    http:Response r = chaosErrorResponse(503);
    test:assertEquals(r.statusCode, 503);
    json body = check r.getJsonPayload();
    test:assertEquals(check body.'error, "chaos-injected");
    test:assertEquals(check body.status, 503);
}

// ---------- parseTraceparent ----------
// The W3C trace-context envelope contract is:
//   00-<32-hex traceId>-<16-hex spanId>-<2-hex flags>
// Any deviation must collapse to ["", ""] so the NATS consumer logs an error
// and skips the message rather than emitting a corrupt trace_id to Splunk.

@test:Config {}
function testParseTraceparentValid() {
    string tp = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";
    [string, string] [tid, sid] = parseTraceparent(tp);
    test:assertEquals(tid, "0af7651916cd43dd8448eb211c80319c");
    test:assertEquals(sid, "b7ad6b7169203331");
}

@test:Config {}
function testParseTraceparentMissingFieldReturnsEmpty() {
    // Only three hyphen-separated fields — flags byte is missing entirely.
    string tp = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331";
    [string, string] [tid, sid] = parseTraceparent(tp);
    test:assertEquals(tid, "");
    test:assertEquals(sid, "");
}

@test:Config {}
function testParseTraceparentWrongVersionByteReturnsEmpty() {
    // Version "ff" is reserved/invalid per W3C; we accept only "00".
    string tp = "ff-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";
    [string, string] [tid, sid] = parseTraceparent(tp);
    test:assertEquals(tid, "");
    test:assertEquals(sid, "");
}

@test:Config {}
function testParseTraceparentNonHexCharsReturnsEmpty() {
    // 'g' is not a hex char — same length, otherwise valid shape.
    string tp = "00-0af7651916cd43dd8448eb211c80319g-b7ad6b7169203331-01";
    [string, string] [tid, sid] = parseTraceparent(tp);
    test:assertEquals(tid, "");
    test:assertEquals(sid, "");
}

@test:Config {}
function testParseTraceparentWrongTraceIdLengthReturnsEmpty() {
    // 31-hex trace_id (one short).
    string tp = "00-0af7651916cd43dd8448eb211c80319-b7ad6b7169203331-01";
    [string, string] [tid, sid] = parseTraceparent(tp);
    test:assertEquals(tid, "");
    test:assertEquals(sid, "");
}

@test:Config {}
function testParseTraceparentWrongSpanIdLengthReturnsEmpty() {
    // 15-hex span_id (one short).
    string tp = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b716920333-01";
    [string, string] [tid, sid] = parseTraceparent(tp);
    test:assertEquals(tid, "");
    test:assertEquals(sid, "");
}

@test:Config {}
function testParseTraceparentEmptyStringReturnsEmpty() {
    [string, string] [tid, sid] = parseTraceparent("");
    test:assertEquals(tid, "");
    test:assertEquals(sid, "");
}
