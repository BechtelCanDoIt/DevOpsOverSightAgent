import ballerina/test;

// ── 7.1 suggest_runbooks scoring ─────────────────────────────────────────────

@test:Config {}
function testSuggestRunbooksChaosSymptom() {
    RunbookSuggestion[] suggestions = suggestRunbooks("payment-service", "502 errors chaos injected");
    test:assertTrue(suggestions.length() > 0, "must return at least one suggestion");
    test:assertEquals(suggestions[0].id, "disable-chaos", "chaos/502 symptoms must rank disable-chaos first");
}

@test:Config {}
function testSuggestRunbooksMemorySymptom() {
    RunbookSuggestion[] suggestions = suggestRunbooks("inventory-service", "memory leak OOM");
    test:assertTrue(suggestions.length() > 0, "must return at least one suggestion");
    test:assertEquals(suggestions[0].id, "restart-service", "memory/OOM symptoms must rank restart-service first");
}

@test:Config {}
function testSuggestRunbooksApplicabilityFilter() {
    RunbookSuggestion[] paymentSuggestions = suggestRunbooks("payment-service", "cache stale redis");
    foreach RunbookSuggestion s in paymentSuggestions {
        test:assertFalse(s.id == "clear-cache", "clear-cache is not listed for payment-service — must be excluded");
    }
    RunbookSuggestion[] inventorySuggestions = suggestRunbooks("inventory-service", "cache stale redis");
    boolean found = false;
    foreach RunbookSuggestion s in inventorySuggestions {
        if s.id == "clear-cache" { found = true; }
    }
    test:assertTrue(found, "clear-cache IS listed for inventory-service and should surface for a matching diagnosis");
}

@test:Config {}
function testSuggestRunbooksProcessCategoryAlwaysEligible() {
    RunbookSuggestion[] suggestions = suggestRunbooks("payment-service", "totally unrelated diagnosis text");
    boolean found = false;
    foreach RunbookSuggestion s in suggestions {
        if s.id == "freeze-deploys" { found = true; }
    }
    test:assertTrue(found, "freeze-deploys is a process runbook and must survive the applicability filter for any service");
}

@test:Config {}
function testSuggestRunbooksRiskTieBreak() {
    // "crash" is an exact restart-service (risk 2) symptom word; "latent"
    // stem-matches disable-chaos's (risk 1) "latency spike" symptom — chosen
    // so both runbooks land on an EQUAL total score (see runbooks.bal scoring
    // walkthrough). On a tie, the lower-risk runbook must sort first.
    RunbookSuggestion[] suggestions = suggestRunbooks("payment-service", "crash latent");
    test:assertTrue(suggestions.length() >= 2, "expected at least disable-chaos and restart-service as candidates");
    test:assertEquals(suggestions[0].score, suggestions[1].score, "test is only meaningful if the top two are tied");
    test:assertEquals(suggestions[0].id, "disable-chaos", "on a tie, lower riskLevel (1) must outrank riskLevel 2");
    test:assertEquals(suggestions[1].id, "restart-service");
}

@test:Config {}
function testSuggestRunbooksUnknownServiceOnlyProcessRunbooks() {
    RunbookSuggestion[] suggestions = suggestRunbooks("no-such-service", "anything");
    foreach RunbookSuggestion s in suggestions {
        RunbookDef? rb = findRunbook(s.id);
        if rb is RunbookDef {
            test:assertEquals(rb.category, "process", "an unknown service has no catalog listing — only process runbooks can survive the filter");
        }
    }
}

// ── 7.1 new scale-service runbook ────────────────────────────────────────────

@test:Config {}
function testListRunbooksContainsScaleService() {
    boolean found = false;
    foreach RunbookDef rb in listRunbooks() { if rb.id == "scale-service" { found = true; } }
    test:assertTrue(found, "scale-service must be in the runbook catalog");
}

// ── 7.2 real restart-service / scale-service (stub fallback, no live backend) ─

@test:Config {}
function testExecuteRestartServiceStubFallback() {
    string[]|error steps = executeRunbook("restart-service", {"service": "payment-service"});
    test:assertFalse(steps is error);
    if steps is string[] {
        boolean foundStubPath = false;
        foreach string s in steps { if s.includes("path=stub") { foundStubPath = true; } }
        test:assertTrue(foundStubPath, "no docker/k8s backend connected in a unit test — must fall back to path=stub");
    }
}

@test:Config {}
function testExecuteScaleServiceStubFallback() {
    string[]|error steps = executeRunbook("scale-service", {"service": "inventory-service", "replicas": "3"});
    test:assertFalse(steps is error);
    if steps is string[] {
        boolean foundStubPath = false;
        foreach string s in steps { if s.includes("path=stub") { foundStubPath = true; } }
        test:assertTrue(foundStubPath, "no k8s backend connected in a unit test — must fall back to path=stub");
    }
}
