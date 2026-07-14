import ballerina/test;

// ── 7.3 computeOverall rollup ─────────────────────────────────────────────

@test:Config {}
function testComputeOverallAllUnavailable() {
    HealthSection[] sections = [
        {'source: "wso2am", status: "UNAVAILABLE", summary: "", details: {}},
        {'source: "wso2is", status: "UNKNOWN", summary: "", details: {}}
    ];
    test:assertEquals(computeOverall(sections), "UNKNOWN");
}

@test:Config {}
function testComputeOverallOneDown() {
    HealthSection[] sections = [
        {'source: "store-service", status: "HEALTHY", summary: "", details: {}},
        {'source: "payment-service", status: "CRITICAL", summary: "", details: {}}
    ];
    test:assertEquals(computeOverall(sections), "CRITICAL");
}

@test:Config {}
function testComputeOverallAlerting() {
    HealthSection[] sections = [
        {'source: "store-service", status: "HEALTHY", summary: "", details: {}},
        {'source: "wso2mi", status: "DEGRADED", summary: "", details: {}}
    ];
    test:assertEquals(computeOverall(sections), "DEGRADED");
}

@test:Config {}
function testComputeOverallEmptyIsUnknown() {
    HealthSection[] sections = [];
    test:assertEquals(computeOverall(sections), "UNKNOWN");
}

// ── product filter (health_report / top_issues shared helper) ───────────────

@test:Config {}
function testProductMatchesEmptyMeansAll() {
    test:assertTrue(productMatches((), "apim", "wso2am"));
    test:assertTrue(productMatches("", "apim", "wso2am"));
}

@test:Config {}
function testProductMatchesTagOrNameSubstring() {
    test:assertTrue(productMatches("apim", "apim", "wso2am"));
    test:assertTrue(productMatches("wso2am", "apim", "wso2am"));
    test:assertFalse(productMatches("mi", "apim", "wso2am"));
}

// ── 7.4 top_issues helpers ───────────────────────────────────────────────────

@test:Config {}
function testCapCountWithinRange() {
    test:assertEquals(capCount(5), 5);
}

@test:Config {}
function testCapCountAboveMaxClampsTo20() {
    test:assertEquals(capCount(9999), 20);
}

@test:Config {}
function testCapCountNegativeClampsToZero() {
    test:assertEquals(capCount(-1), 0);
}

@test:Config {}
function testSortIssuesByScoreDesc() {
    Issue[] issues = [
        {'source: "a", severity: "P3", target: "x", title: "low", evidence: "", score: 2},
        {'source: "b", severity: "P1", target: "y", title: "high", evidence: "", score: 10},
        {'source: "c", severity: "P2", target: "z", title: "mid", evidence: "", score: 6}
    ];
    sortIssuesByScoreDesc(issues);
    test:assertEquals(issues[0].title, "high");
    test:assertEquals(issues[1].title, "mid");
    test:assertEquals(issues[2].title, "low");
}

// apim/mi/is anomaly extraction — pure JSON parsing, no live backend needed.
// Fixtures mirror the real mock servers' actual response shape exactly
// (code/mcp/apim-mcp|mi-mcp|is-mcp mock_data.bal).

@test:Config {}
function testAppendApimAnomaliesFindsBlockedApi() {
    Issue[] issues = [];
    string fixture = string `[{"id":"api-001","name":"PaymentAPI","version":"1.0.0","context":"/payment","lifeCycleStatus":"PUBLISHED","type":"HTTP"},
        {"id":"api-003","name":"LegacyBillingAPI","version":"0.9.0","context":"/legacy-billing","lifeCycleStatus":"BLOCKED","type":"HTTP"}]`;
    appendApimAnomalies(issues, fixture);
    test:assertEquals(issues.length(), 1);
    test:assertEquals(issues[0].target, "LegacyBillingAPI");
    test:assertEquals(issues[0].'source, "apim");
    test:assertEquals(issues[0].score, 6);
}

@test:Config {}
function testAppendMiAnomaliesFindsInactiveProcessor() {
    Issue[] issues = [];
    string fixture = string `[{"name":"order-retry-processor","state":"INACTIVE","messageCount":47},
        {"name":"notification-dispatch-processor","state":"ACTIVE","messageCount":0}]`;
    appendMiAnomalies(issues, fixture);
    test:assertEquals(issues.length(), 1);
    test:assertEquals(issues[0].target, "order-retry-processor");
    test:assertTrue(issues[0].evidence.includes("47"));
}

@test:Config {}
function testAppendIsAnomaliesFindsDisconnectedStore() {
    Issue[] issues = [];
    string fixture = string `[{"name":"PRIMARY","status":"Active"},{"name":"SECONDARY","status":"Disconnected"}]`;
    appendIsAnomalies(issues, fixture);
    test:assertEquals(issues.length(), 1);
    test:assertEquals(issues[0].target, "SECONDARY");
}

@test:Config {}
function testAppendK8sWarningsBestEffortParsing() {
    Issue[] issues = [];
    string fixture = string `[{"type":"Normal","reason":"Scheduled","involvedObjectName":"pod-a"},
        {"type":"Warning","reason":"BackOff","involvedObjectName":"pod-b"}]`;
    appendK8sWarnings(issues, fixture);
    test:assertEquals(issues.length(), 1);
    test:assertEquals(issues[0].target, "pod-b");
    test:assertEquals(issues[0].title, "BackOff");
}

@test:Config {}
function testAppendK8sWarningsMalformedInputYieldsNoIssues() {
    Issue[] issues = [];
    appendK8sWarnings(issues, "not valid json");
    test:assertEquals(issues.length(), 0);
}

// ── 7.5 list_deployments ─────────────────────────────────────────────────────

@test:Config {}
function testListDeploymentsHasThreeWso2Entries() {
    DeploymentInfo[] deployments = listDeployments();
    int wso2Count = 0;
    foreach DeploymentInfo d in deployments {
        if d.product != "mesh" { wso2Count += 1; }
    }
    test:assertEquals(wso2Count, 3, "must have exactly wso2am/wso2mi/wso2is");
}

@test:Config {}
function testListDeploymentsHasSevenMeshEntries() {
    DeploymentInfo[] deployments = listDeployments();
    int meshCount = 0;
    foreach DeploymentInfo d in deployments {
        if d.product == "mesh" { meshCount += 1; }
    }
    test:assertEquals(meshCount, 7);
}

// ── json field-extraction helpers ────────────────────────────────────────────

@test:Config {}
function testJsonStringFieldFallbackOnMissingKey() {
    json obj = {name: "x"};
    test:assertEquals(jsonStringField(obj, "missing", "fallback"), "fallback");
}

@test:Config {}
function testJsonIntFieldFallbackOnWrongType() {
    json obj = {count: "not-an-int"};
    test:assertEquals(jsonIntField(obj, "count", -1), -1);
}

@test:Config {}
function testSlaAtOrAbove999() {
    test:assertTrue(slaAtOrAbove999("99.99%"));
    test:assertTrue(slaAtOrAbove999("99.9%"));
    test:assertFalse(slaAtOrAbove999("99.5%"));
}
