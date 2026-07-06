import ballerina/http;
import ballerina/os;
import ballerina/test;

// ── envOr ────────────────────────────────────────────────────────────────────
// Two paths: (a) env var unset/empty → fallback; (b) env var set → value.

@test:Config {}
function testEnvOrFallbackWhenUnset() {
    // An env name we don't expect anyone to set in the test environment.
    string v = envOr("CUSTOMER_TEST_UNSET_VAR_XYZ", "fallback-default");
    test:assertEquals(v, "fallback-default",
        msg = "envOr should return fallback when env var is unset/empty");
}

@test:Config {}
function testEnvOrReturnsValueWhenSet() returns error? {
    string key = "CUSTOMER_TEST_SET_VAR_XYZ";
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
// CHAOS_TOKEN default is "dev-chaos-token" (see chaos.bal). Tests read the
// same way the module did, so the assertion stays valid even if the env
// overrides the default.

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

// ── buildCustomer (response shape) ───────────────────────────────────────────
// Verifies the response record produced from a generated id + payload.

@test:Config {}
function testBuildCustomerShape() {
    NewCustomer payload = {name: "Alice Johnson", email: "alice@example.com"};
    Customer c = buildCustomer(42, payload);
    test:assertEquals(c.id, 42, msg = "id should be carried through");
    test:assertEquals(c.name, "Alice Johnson", msg = "name should match payload");
    test:assertEquals(c.email, "alice@example.com", msg = "email should match payload");
}

// ── validateNewCustomer ──────────────────────────────────────────────────────
// Covers: happy path, empty/whitespace name, empty email, malformed email.

@test:Config {}
function testValidateNewCustomerAccepts() {
    NewCustomer ok = {name: "Bob Smith", email: "bob@example.com"};
    error? r = validateNewCustomer(ok);
    test:assertTrue(r is (), msg = "well-formed payload should validate");
}

@test:Config {}
function testValidateNewCustomerRejects() {
    NewCustomer blankName = {name: "   ", email: "x@example.com"};
    test:assertTrue(validateNewCustomer(blankName) is error,
        msg = "whitespace-only name must be rejected");

    NewCustomer blankEmail = {name: "Eve", email: ""};
    test:assertTrue(validateNewCustomer(blankEmail) is error,
        msg = "empty email must be rejected");

    NewCustomer noAt = {name: "Dan", email: "dan-at-example.com"};
    test:assertTrue(validateNewCustomer(noAt) is error,
        msg = "email without '@' must be rejected");
}

// ── isValidCustomerId ────────────────────────────────────────────────────────

@test:Config {}
function testIsValidCustomerId() {
    test:assertTrue(isValidCustomerId(1),   msg = "id == 1 is valid");
    test:assertTrue(isValidCustomerId(999), msg = "large positive id is valid");
    test:assertFalse(isValidCustomerId(0),  msg = "id == 0 must be rejected");
    test:assertFalse(isValidCustomerId(-1), msg = "negative id must be rejected");
}
