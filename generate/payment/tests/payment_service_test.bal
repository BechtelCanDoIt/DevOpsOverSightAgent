import ballerina/http;
import ballerina/os;
import ballerina/test;

// ---------------------------------------------------------------------------
// obs.bal — envOr
// ---------------------------------------------------------------------------

// envOr returns the fallback when the env var is unset/empty.
@test:Config {}
function testEnvOrReturnsFallbackWhenUnset() {
    // Use a name that is overwhelmingly unlikely to exist in the test env.
    string actual = envOr("PAYMENT_TEST_DEFINITELY_UNSET_VAR_XYZ", "fallback-value");
    test:assertEquals(actual, "fallback-value",
            "envOr should return the fallback when the env var is unset");
}

// envOr returns the env value when set.
@test:Config {}
function testEnvOrReturnsEnvValueWhenSet() returns error? {
    string name = "PAYMENT_TEST_ENVOR_SET_VAR";
    error? setRes = os:setEnv(name, "from-env");
    if setRes is error {
        test:assertFail(msg = "os:setEnv should not fail");
    }
    string actual = envOr(name, "fallback-value");
    test:assertEquals(actual, "from-env",
            "envOr should return the env value when it is set");
    check os:unsetEnv(name);
}

// ---------------------------------------------------------------------------
// chaos.bal — chaosAuthed
// ---------------------------------------------------------------------------

// Negative path: a wrong/empty/nil token must not be authorized.
@test:Config {}
function testChaosAuthedRejectsBadToken() {
    test:assertFalse(chaosAuthed(()), "nil token must not authorize");
    test:assertFalse(chaosAuthed(""), "empty token must not authorize");
    test:assertFalse(chaosAuthed("wrong-token"), "wrong token must not authorize");
}

// Positive path: passing the resolved chaos token authorizes.
// Recompute the expected value the same way the module did at init time so
// the test is robust to whatever `CHAOS_TOKEN` is set to (or the default).
@test:Config {}
function testChaosAuthedAcceptsConfiguredToken() {
    string expected = envOr("CHAOS_TOKEN", "dev-chaos-token");
    test:assertTrue(chaosAuthed(expected),
            "chaosAuthed must accept the configured chaos token");
}

// ---------------------------------------------------------------------------
// chaos.bal — chaosErrorResponse
// ---------------------------------------------------------------------------

@test:Config {}
function testChaosErrorResponseShape() returns error? {
    http:Response r = chaosErrorResponse(503);
    test:assertEquals(r.statusCode, 503, "status code must match the requested status");

    json payload = check r.getJsonPayload();
    // Expected shape: { "error": "chaos-injected", "status": 503 }
    map<json> m = <map<json>>payload;
    test:assertEquals(m["error"], "chaos-injected",
            "payload.error must be the chaos-injected sentinel");
    test:assertEquals(m["status"], 503,
            "payload.status must echo the injected status");
}

@test:Config {}
function testChaosErrorResponsePropagatesArbitraryStatus() returns error? {
    http:Response r = chaosErrorResponse(418);
    test:assertEquals(r.statusCode, 418);

    json payload = check r.getJsonPayload();
    map<json> m = <map<json>>payload;
    test:assertEquals(m["status"], 418);
}

// ---------------------------------------------------------------------------
// main.bal — mockBankAuthorize (pure, deterministic-on-shape)
// ---------------------------------------------------------------------------

// mockBankAuthorize is the in-process stand-in for the bank. It must:
//   - always approve (this POC's mock is happy-path),
//   - return an authId prefixed with "AUTH-",
//   - include currency + amount in the human-readable note.
@test:Config {}
function testMockBankAuthorizeApprovesAndShapesNote() {
    decimal amount = 42d;
    BankAuthorization auth = mockBankAuthorize(amount, "USD");

    test:assertTrue(auth.approved, "mock bank must approve in this POC");
    test:assertTrue(auth.authId.startsWith("AUTH-"),
            "authId should be prefixed with AUTH-, got: " + auth.authId);
    test:assertTrue(auth.note.includes("USD"),
            "note should mention the currency, got: " + auth.note);
    test:assertTrue(auth.note.includes("mock-bank approved"),
            "note should describe the mock bank approval, got: " + auth.note);
}

// Each call should mint a distinct authorization id (UUID-backed).
@test:Config {}
function testMockBankAuthorizeProducesUniqueAuthIds() {
    BankAuthorization a = mockBankAuthorize(1.00d, "USD");
    BankAuthorization b = mockBankAuthorize(1.00d, "USD");
    test:assertNotEquals(a.authId, b.authId,
            "successive calls must yield distinct auth ids");
}

// ---------------------------------------------------------------------------
// main.bal — ChargeRequest record defaults
// ---------------------------------------------------------------------------

// The ChargeRequest record defaults currency to "USD" when callers omit it.
// This is the only request-shape "validation" the service relies on.
@test:Config {}
function testChargeRequestDefaultsCurrencyToUsd() {
    ChargeRequest req = {amount: 10.00d, orderId: "ORD-1"};
    test:assertEquals(req.currency, "USD",
            "ChargeRequest.currency must default to USD when omitted");
}
