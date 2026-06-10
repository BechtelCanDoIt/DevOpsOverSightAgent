import ballerina/test;

// Catalog tests
@test:Config {}
function testCatalogLookupKnownService() {
    ServiceInfo? r = catalogLookup("payment-service");
    test:assertFalse(r is (), "payment-service must be in catalog");
    if r is ServiceInfo {
        test:assertEquals(r.owner, "payments-team");
        test:assertEquals(r.sla, "99.99%");
    }
}

@test:Config {}
function testCatalogLookupUnknown() {
    test:assertTrue(catalogLookup("no-such-service") is (), "unknown service returns ()");
}

@test:Config {}
function testListAllServicesCount() {
    test:assertEquals(listAllServices().length(), 7, "must have 7 services");
}

@test:Config {}
function testGetDependenciesDownstreamOrder() {
    string[] deps = getDependencies("order-service", "downstream");
    test:assertTrue(deps.length() >= 4, "order has at least 4 downstream deps");
    boolean hasPayment = false; boolean hasNotif = false;
    foreach string d in deps {
        if d == "payment-service" { hasPayment = true; }
        if d == "notification-service" { hasNotif = true; }
    }
    test:assertTrue(hasPayment, "order must depend on payment");
    test:assertTrue(hasNotif, "order must depend on notification (async)");
}

@test:Config {}
function testGetDependenciesUpstreamPayment() {
    string[] up = getDependencies("payment-service", "upstream");
    test:assertTrue(up.length() >= 1, "payment must have upstream callers");
    boolean hasOrder = false;
    foreach string u in up { if u == "order-service" { hasOrder = true; } }
    test:assertTrue(hasOrder, "order must be upstream of payment");
}

@test:Config {}
function testGetDependenciesUpstreamNotification() {
    string[] up = getDependencies("notification-service", "upstream");
    boolean hasOrder = false;
    foreach string u in up { if u == "order-service" { hasOrder = true; } }
    test:assertTrue(hasOrder, "order must be upstream of notification (NATS async)");
}

@test:Config {}
function testGetDependenciesBothInventory() {
    string[] both = getDependencies("inventory-service", "both");
    boolean hasStore = false; boolean hasOrder = false;
    foreach string b in both {
        if b == "store-service" { hasStore = true; }
        if b == "order-service" { hasOrder = true; }
    }
    test:assertTrue(hasStore, "store must be upstream of inventory");
    test:assertTrue(hasOrder, "order must be upstream of inventory");
}

@test:Config {}
function testLeafServiceHasNoDownstream() {
    test:assertEquals(getDependencies("customer-service", "downstream").length(), 0);
}

// Correlation tests
@test:Config {}
function testDatadogUrlFormat() {
    string url = buildDatadogTraceUrl("abc123", "datadoghq.com");
    test:assertEquals(url, "https://app.datadoghq.com/apm/trace/abc123");
}

@test:Config {}
function testDatadogUrlCustomSite() {
    test:assertEquals(
        buildDatadogTraceUrl("tid", "us5.datadoghq.com"),
        "https://app.us5.datadoghq.com/apm/trace/tid");
}

@test:Config {}
function testSplunkSplContainsTraceId() {
    string spl = buildSplunkSpl("mytraceid");
    test:assertTrue(spl.startsWith("index=*"), "SPL must start with index=*");
    test:assertTrue(spl.includes("mytraceid"), "SPL must include the trace_id");
}

@test:Config {}
function testInferInvolvedServicesReturnsAll() {
    test:assertEquals(inferInvolvedServices("any").length(), 7);
}

// Deploy stub tests
@test:Config {}
function testFindDeploysForPayment() {
    test:assertTrue(findRecentDeploys("payment-service", 9999).length() > 0);
}

@test:Config {}
function testFindDeploysUnknownService() {
    test:assertEquals(findRecentDeploys("no-such-service", 60).length(), 0);
}

// Incident stub tests
@test:Config {}
function testFindIncidentsForPayment() {
    test:assertTrue(findRelatedIncidents("payment-service", 30).length() > 0);
}

// Runbook tests
@test:Config {}
function testListRunbooksFour() {
    test:assertEquals(listRunbooks().length(), 4);
}

@test:Config {}
function testListRunbooksContainsDisableChaos() {
    boolean found = false;
    foreach RunbookDef rb in listRunbooks() { if rb.id == "disable-chaos" { found = true; } }
    test:assertTrue(found, "disable-chaos must be in runbooks");
}

@test:Config {}
function testRunDisableChaosReturnsSteps() {
    string[]|error steps = executeRunbook("disable-chaos", {"service": "payment-service"});
    test:assertFalse(steps is error);
    if steps is string[] { test:assertTrue(steps.length() > 0); }
}

@test:Config {}
function testRunClearCacheReturnsSteps() {
    string[]|error steps = executeRunbook("clear-cache", {});
    test:assertFalse(steps is error);
}

@test:Config {}
function testRunFreezeDeploys() {
    string[]|error steps = executeRunbook("freeze-deploys", {"reason": "test"});
    test:assertFalse(steps is error);
    test:assertTrue(isDeployFrozen(), "deploy must be frozen after runbook");
}

@test:Config {}
function testRunUnknownRunbookErrors() {
    string[]|error steps = executeRunbook("no-such-runbook", {});
    test:assertTrue(steps is error, "unknown runbook must return error");
}

@test:Config {}
function testAuditLogPopulated() {
    string[]|error auditResult = executeRunbook("restart-service", {"service": "payment-service"});
    boolean ignored = auditResult is error;
    test:assertTrue(getAuditLog().length() > 0, "audit log must have entries after runbook");
}
