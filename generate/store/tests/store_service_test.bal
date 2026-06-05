// Unit tests for store-service.
//
// Scope: pure helpers only — no Postgres, no HTTP to inventory-service.
// The DB client / inventoryClient init in service.bal still runs on test
// startup (module init), so these tests assume a compose/local environment
// where those connectors are reachable OR they are run with `bal test` after
// the DB is up. The functions exercised here themselves do no IO.

import ballerina/http;
import ballerina/os;
import ballerina/test;

// ---- envOr ----------------------------------------------------------------

@test:Config {}
function testEnvOrReturnsFallbackWhenUnset() {
    // Use a name extremely unlikely to be set in any environment.
    string v = envOr("STORE_SVC_TEST_DEFINITELY_UNSET_VAR", "fallback-value");
    test:assertEquals(v, "fallback-value");
}

@test:Config {}
function testEnvOrReturnsValueWhenSet() returns error? {
    string name = "STORE_SVC_TEST_SET_VAR";
    error? setRes = os:setEnv(name, "real-value");
    if setRes is error {
        test:assertFail(msg = "os:setEnv should not fail");
    }
    string v = envOr(name, "fallback-value");
    test:assertEquals(v, "real-value");
    check os:unsetEnv(name);
}

// ---- chaosAuthed ----------------------------------------------------------

@test:Config {}
function testChaosAuthedAcceptsConfiguredToken() {
    // Resolve the same way chaos.bal does so the assertion holds whether or not
    // CHAOS_TOKEN is set in the test environment.
    string expected = envOr("CHAOS_TOKEN", "dev-chaos-token");
    test:assertTrue(chaosAuthed(expected),
            msg = "expected the configured CHAOS_TOKEN to authenticate");
}

@test:Config {}
function testChaosAuthedRejectsWrongAndMissingToken() {
    test:assertFalse(chaosAuthed("definitely-not-the-token"),
            msg = "wrong token must be rejected");
    test:assertFalse(chaosAuthed(()),
            msg = "missing token must be rejected");
}

// ---- chaosErrorResponse ---------------------------------------------------

@test:Config {}
function testChaosErrorResponseShape() returns error? {
    http:Response r = chaosErrorResponse(503);
    test:assertEquals(r.statusCode, 503, msg = "status code should match the argument");

    json body = check r.getJsonPayload();
    test:assertEquals(body, <json>{'error: "chaos-injected", status: 503},
            msg = "payload should be the canonical chaos-injected envelope");
}

// ---- buildProductDetail (pure mapper) -------------------------------------

@test:Config {}
function testBuildProductDetailInStock() {
    Product p = {id: 1, name: "Aerodynamic Water Bottle", sku: "SKU-001", price: 18.99d};
    ProductDetail d = buildProductDetail(p, 7);
    test:assertEquals(d.id, 1);
    test:assertEquals(d.name, "Aerodynamic Water Bottle");
    test:assertEquals(d.sku, "SKU-001");
    test:assertEquals(d.price, 18.99d);
    test:assertEquals(d?.stock, 7);
    test:assertEquals(d.availability, "in_stock");
}

@test:Config {}
function testBuildProductDetailOutOfStockAndUnknown() {
    Product p = {id: 2, name: "Wireless Earbuds", sku: "SKU-002", price: 79.50d};

    // stock == 0 → out_of_stock, with stock field still populated as 0.
    ProductDetail zero = buildProductDetail(p, 0);
    test:assertEquals(zero.availability, "out_of_stock");
    test:assertEquals(zero?.stock, 0);

    // stock == () → graceful degradation: availability "unknown", stock nil.
    ProductDetail unknown = buildProductDetail(p, ());
    test:assertEquals(unknown.availability, "unknown");
    test:assertTrue(unknown?.stock is (), msg = "stock must be nil when inventory unavailable");
}

// ---- skuValid -------------------------------------------------------------

@test:Config {}
function testSkuValidAcceptsSeededSkus() {
    // The catalog seed uses SKU-001..SKU-005; all must validate.
    test:assertTrue(skuValid("SKU-001"));
    test:assertTrue(skuValid("SKU-005"));
    test:assertTrue(skuValid("SKU-999"));
}

@test:Config {}
function testSkuValidRejectsMalformed() {
    test:assertFalse(skuValid(""), msg = "empty");
    test:assertFalse(skuValid("SKU-01"), msg = "too short");
    test:assertFalse(skuValid("SKU-0001"), msg = "too long");
    test:assertFalse(skuValid("sku-001"), msg = "wrong case prefix");
    test:assertFalse(skuValid("SKU_001"), msg = "wrong separator");
    test:assertFalse(skuValid("SKU-00A"), msg = "non-digit suffix");
}
