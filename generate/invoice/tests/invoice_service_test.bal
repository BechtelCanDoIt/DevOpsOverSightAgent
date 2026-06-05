// Unit tests for the invoice-service pure surface: env reading, chaos auth,
// chaos error responses, request validation, and row/response mapping.
// DB-backed handlers are out of scope here (no live Postgres in unit tests).

import ballerina/http;
import ballerina/os;
import ballerina/test;

// ---------- envOr ----------

@test:Config {}
function testEnvOrReturnsFallbackWhenUnset() {
    // Use a name extremely unlikely to be set in the test environment.
    string v = envOr("INVOICE_TEST_DOES_NOT_EXIST_XYZ", "fallback-val");
    test:assertEquals(v, "fallback-val");
}

@test:Config {}
function testEnvOrReturnsEnvValueWhenSet() returns error? {
    string varName = "INVOICE_TEST_ENV_OR_VAR";
    check os:setEnv(varName, "actual-val");
    string v = envOr(varName, "fallback-val");
    test:assertEquals(v, "actual-val");
    check os:unsetEnv(varName);
}

// ---------- chaosAuthed ----------

@test:Config {}
function testChaosAuthedAcceptsConfiguredToken() {
    // chaosToken is initialized from envOr("CHAOS_TOKEN", "dev-chaos-token").
    // The test env does not set CHAOS_TOKEN, so the fallback applies.
    test:assertTrue(chaosAuthed("dev-chaos-token"));
}

@test:Config {}
function testChaosAuthedRejectsBadAndMissingToken() {
    test:assertFalse(chaosAuthed("nope"));
    test:assertFalse(chaosAuthed(()));
    test:assertFalse(chaosAuthed(""));
}

// ---------- chaosErrorResponse ----------

@test:Config {}
function testChaosErrorResponseShape() returns error? {
    http:Response r = chaosErrorResponse(503);
    test:assertEquals(r.statusCode, 503);
    json payload = check r.getJsonPayload();
    test:assertEquals((check payload.'error).toString(), "chaos-injected");
    test:assertEquals(check payload.status, 503);
}

// ---------- validateNewInvoice ----------

@test:Config {}
function testValidateNewInvoiceAcceptsValidPayload() {
    NewInvoice req = {orderId: "ord-1", amount: 42.50d};
    error? r = validateNewInvoice(req);
    test:assertTrue(r is (), "expected validation to pass for a well-formed payload");
}

@test:Config {}
function testValidateNewInvoiceRejectsEmptyOrderId() {
    NewInvoice blank = {orderId: "", amount: 10d};
    error? r1 = validateNewInvoice(blank);
    test:assertTrue(r1 is error, "empty orderId must be rejected");

    NewInvoice whitespace = {orderId: "   ", amount: 10d};
    error? r2 = validateNewInvoice(whitespace);
    test:assertTrue(r2 is error, "whitespace-only orderId must be rejected");
}

@test:Config {}
function testValidateNewInvoiceRejectsNonPositiveAmount() {
    NewInvoice zero = {orderId: "ord-1", amount: 0d};
    error? r1 = validateNewInvoice(zero);
    test:assertTrue(r1 is error, "zero amount must be rejected");

    NewInvoice negative = {orderId: "ord-1", amount: -1.25d};
    error? r2 = validateNewInvoice(negative);
    test:assertTrue(r2 is error, "negative amount must be rejected");
}

// ---------- rowToInvoice / newIssuedInvoice ----------

@test:Config {}
function testRowToInvoiceMapsAllFields() {
    InvoiceRow row = {id: 7, order_id: "ord-7", amount: 99.99d, status: "paid"};
    Invoice inv = rowToInvoice(row);
    test:assertEquals(inv.invoiceId, 7);
    test:assertEquals(inv.orderId, "ord-7");
    test:assertEquals(inv.amount, 99.99d);
    test:assertEquals(inv.status, "paid");
}

@test:Config {}
function testNewIssuedInvoiceShape() {
    NewInvoice req = {orderId: "ord-42", amount: 12.34d};
    Invoice inv = newIssuedInvoice(101, req);
    test:assertEquals(inv.invoiceId, 101);
    test:assertEquals(inv.orderId, "ord-42");
    test:assertEquals(inv.amount, 12.34d);
    test:assertEquals(inv.status, "issued", "freshly issued invoices must start in 'issued' state");
}
