// Unit tests for the order-service pure helpers.
//
// Scope: only functions that do not require a live Postgres / Redis / NATS /
// downstream-HTTP dependency. The full /orders orchestrator path is exercised
// in the demo end-to-end (Phase 5), not here.
//
// Run with: `bal test` from generate/order/.

import ballerina/http;
import ballerina/os;
import ballerina/test;

// ── envOr (obs.bal) ──────────────────────────────────────────────────────────
// Two paths: (a) env var unset/empty → fallback; (b) env var set → value.

@test:Config {}
function testEnvOrFallbackWhenUnset() {
    // An env name we don't expect anyone to set in the test environment.
    string v = envOr("ORDER_TEST_UNSET_VAR_XYZ", "fallback-default");
    test:assertEquals(v, "fallback-default",
        msg = "envOr should return fallback when env var is unset/empty");
}

@test:Config {}
function testEnvOrReturnsValueWhenSet() returns error? {
    string key = "ORDER_TEST_SET_VAR_XYZ";
    check os:setEnv(key, "hello-env");
    string v = envOr(key, "should-not-be-used");
    test:assertEquals(v, "hello-env",
        msg = "envOr should return the env-var value when set");
    check os:unsetEnv(key);
}

// ── chaosAuthed (chaos.bal) ──────────────────────────────────────────────────
// CHAOS_TOKEN default is "dev-chaos-token" (see chaos.bal). Read it the same
// way the module did so the assertion holds even if the env overrides it.

@test:Config {}
function testChaosAuthedPositive() {
    string expected = envOr("CHAOS_TOKEN", "dev-chaos-token");
    test:assertTrue(chaosAuthed(expected),
        msg = "chaosAuthed should accept the configured token");
}

@test:Config {}
function testChaosAuthedNegative() {
    test:assertFalse(chaosAuthed("definitely-not-the-token"),
        msg = "chaosAuthed should reject a wrong token");
    test:assertFalse(chaosAuthed(()),
        msg = "chaosAuthed should reject a nil token");
    test:assertFalse(chaosAuthed(""),
        msg = "chaosAuthed should reject an empty-string token");
}

// ── chaosErrorResponse (chaos.bal) ───────────────────────────────────────────

@test:Config {}
function testChaosErrorResponseStatusAndPayload() returns error? {
    http:Response r = chaosErrorResponse(503);
    test:assertEquals(r.statusCode, 503,
        msg = "status code should match the argument");

    json body = check r.getJsonPayload();
    test:assertEquals(body, <json>{'error: "chaos-injected", status: 503},
        msg = "payload should be the canonical chaos-injected envelope");
}

// ── buildTraceparent (order_service.bal) ─────────────────────────────────────
// The W3C trace-context envelope is the contract that lets `notification`
// rejoin the order trace in Splunk over NATS (see CONVENTIONS.md "NATS
// trace-propagation envelope"). The format is load-bearing.

@test:Config {}
function testBuildTraceparentFormat() {
    string tid = "0af7651916cd43dd8448eb211c80319c";   // 32-hex
    string sid = "b7ad6b7169203331";                   // 16-hex
    string tp = buildTraceparent(tid, sid);
    test:assertEquals(tp,
        "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
        msg = "traceparent must follow W3C format 00-<traceId>-<spanId>-01");
}

@test:Config {}
function testBuildTraceparentEmptyIdsStillWellFormed() {
    // Outside an active span context spanCtx() returns ["", ""]; the envelope
    // is still constructed (notification will just see empty ids) — verify
    // the version/flags fences are preserved.
    string tp = buildTraceparent("", "");
    test:assertEquals(tp, "00---01",
        msg = "traceparent with empty ids must still keep the '00-' / '-01' fences");
}

// ── newOrderId (order_service.bal) ───────────────────────────────────────────
// Format: ORD-<millis>-<4-digit-suffix>.

@test:Config {}
function testNewOrderIdFormat() {
    string id = newOrderId();
    test:assertTrue(id.startsWith("ORD-"),
        msg = "newOrderId must start with the 'ORD-' prefix");

    // Expect three dash-separated segments: "ORD", millis, suffix.
    string[] parts = re `-`.split(id);
    test:assertEquals(parts.length(), 3,
        msg = "newOrderId must have exactly two dashes (three segments)");
    test:assertEquals(parts[0], "ORD");

    // millis segment is a positive integer.
    int|error millis = int:fromString(parts[1]);
    if millis is error {
        test:assertFail(msg = "millis segment must be an integer, got: " + parts[1]);
    } else {
        test:assertTrue(millis > 0, msg = "millis segment must be positive");
    }

    // Suffix is a 4-digit integer in [1000, 9999].
    test:assertEquals(parts[2].length(), 4, msg = "suffix must be 4 digits");
    int|error suffix = int:fromString(parts[2]);
    if suffix is error {
        test:assertFail(msg = "suffix segment must be an integer, got: " + parts[2]);
    } else {
        test:assertTrue(suffix >= 1000 && suffix <= 9999,
            msg = "suffix must be in [1000, 9999]");
    }
}

@test:Config {}
function testNewOrderIdIsReasonablyUnique() {
    // Not a strong uniqueness guarantee (millis + random) but two back-to-back
    // calls should not collide; this catches the obvious "constant" regression.
    string a = newOrderId();
    string b = newOrderId();
    test:assertNotEquals(a, b,
        msg = "two consecutive newOrderId() calls must differ");
}
