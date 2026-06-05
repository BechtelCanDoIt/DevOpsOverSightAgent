import ballerina/http;
import ballerina/os;
import ballerina/test;

// ── envOr ────────────────────────────────────────────────────────────────────
// Two paths: (a) env var unset/empty → fallback; (b) env var set → value.

@test:Config {}
function testEnvOrFallbackWhenUnset() {
    // An env name we don't expect anyone to set in the test environment.
    string v = envOr("INVENTORY_TEST_UNSET_VAR_XYZ", "fallback-default");
    test:assertEquals(v, "fallback-default",
        msg = "envOr should return fallback when env var is unset/empty");
}

@test:Config {}
function testEnvOrReturnsValueWhenSet() returns error? {
    string key = "INVENTORY_TEST_SET_VAR_XYZ";
    error? setRes = os:setEnv(key, "hello-env");
    if setRes is error {
        test:assertFail(msg = "os:setEnv should not fail");
    }
    string v = envOr(key, "should-not-be-used");
    test:assertEquals(v, "hello-env",
        msg = "envOr should return the env-var value when set");
    check os:unsetEnv(key);
}

// ── chaosAuthed ──────────────────────────────────────────────────────────────
// CHAOS_TOKEN default is "dev-chaos-token" (see chaos.bal). Tests assume the
// default; if the env overrides it, we still exercise the negative path.

@test:Config {}
function testChaosAuthedPositive() {
    // chaosToken is initialised from envOr("CHAOS_TOKEN", "dev-chaos-token").
    // Read the same way the module did, so the assertion stays valid even if
    // the env overrides the default.
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
}

// ── chaosErrorResponse ───────────────────────────────────────────────────────

@test:Config {}
function testChaosErrorResponseStatusAndPayload() returns error? {
    http:Response r = chaosErrorResponse(503);
    test:assertEquals(r.statusCode, 503,
        msg = "status code should match the argument");

    json body = check r.getJsonPayload();
    test:assertEquals(body, <json>{'error: "chaos-injected", status: 503},
        msg = "payload should be the canonical chaos-injected envelope");
}

// ── cacheKey ─────────────────────────────────────────────────────────────────

@test:Config {}
function testCacheKeyDerivation() {
    test:assertEquals(cacheKey("SKU-001"), "stock:SKU-001",
        msg = "cacheKey should prefix sku with 'stock:'");
    test:assertEquals(cacheKey(""), "stock:",
        msg = "cacheKey should handle empty sku deterministically");
}

// ── canReserve (reservation guard) ───────────────────────────────────────────
// Covers: positive case, non-positive qty rejected, would-go-negative rejected,
// and the exact-boundary (current == qty) case.

@test:Config {}
function testCanReserveAccepts() {
    test:assertTrue(canReserve(100, 1),  msg = "small draw against ample stock");
    test:assertTrue(canReserve(10, 10),  msg = "exact-boundary draw should succeed");
}

@test:Config {}
function testCanReserveRejects() {
    test:assertFalse(canReserve(5, 0),   msg = "qty == 0 must be rejected");
    test:assertFalse(canReserve(5, -3),  msg = "negative qty must be rejected");
    test:assertFalse(canReserve(5, 6),   msg = "qty > current must be rejected (no negative stock)");
    test:assertFalse(canReserve(0, 1),   msg = "drawing from empty stock must be rejected");
}
