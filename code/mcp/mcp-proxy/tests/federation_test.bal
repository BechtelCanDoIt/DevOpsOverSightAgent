import ballerina/test;

// ── scoreToolMatch (moved from the agent package) ─────────────────────────────

@test:Config {}
function testScoreToolMatchExactWord() {
    int score = scoreToolMatch("splunk__splunk_run_query", "[splunk] Run an SPL query", "splunk query");
    test:assertTrue(score > 0, "should match 'splunk' and 'query'");
}

@test:Config {}
function testScoreToolMatchNoMatch() {
    int score = scoreToolMatch("topology__lookup_service", "[topology] Look up a service by name", "kubernetes deployment");
    test:assertEquals(score, 0, "should not match unrelated query");
}

@test:Config {}
function testScoreToolMatchPrefixHandlesPlurals() {
    int score = scoreToolMatch("datadog__search_datadog_monitors", "[datadog] Search monitors by name or tag", "datadog monitors alerts");
    test:assertTrue(score > 0, "should match via 'datadog' exact and 'moni' prefix");
}

@test:Config {}
function testScoreToolMatchShortWordsIgnored() {
    int score = scoreToolMatch("topology__list_services", "[topology] List all 7 mesh services", "a of in");
    test:assertEquals(score, 0, "words of length <= 2 must be ignored");
}

@test:Config {}
function testScoreToolMatchMultiWordScoresHigher() {
    int two = scoreToolMatch("splunk__splunk_run_query", "[splunk] Run an SPL query", "splunk query");
    int one = scoreToolMatch("splunk__splunk_run_query", "[splunk] Run an SPL query", "splunk");
    test:assertTrue(two > one, "two matching query words must score higher than one");
}

// ── searchRegistry (moved from the agent package) ─────────────────────────────

@test:Config {}
function testSearchRegistryRanksTopMatch() {
    map<RegistryEntry> registry = {
        "splunk__splunk_run_query": {name: "splunk__splunk_run_query", description: "[splunk] Run an SPL query", inputSchema: {}},
        "topology__lookup_service": {name: "topology__lookup_service", description: "[topology] Look up a service", inputSchema: {}},
        "datadog__get_datadog_metric": {name: "datadog__get_datadog_metric", description: "[datadog] Get a metric time series", inputSchema: {}}
    };
    RegistryEntry[] results = searchRegistry(registry, "splunk query logs", 5);
    test:assertTrue(results.length() > 0, "should find at least one tool");
    test:assertEquals(results[0].name, "splunk__splunk_run_query", "top result should be the splunk query tool");
}

@test:Config {}
function testSearchRegistryEmptyOnNoMatch() {
    map<RegistryEntry> registry = {
        "topology__lookup_service": {name: "topology__lookup_service", description: "[topology] Look up a service", inputSchema: {}}
    };
    RegistryEntry[] results = searchRegistry(registry, "kubernetes fargate lambda zzzunknown", 5);
    test:assertEquals(results.length(), 0, "should return empty array when nothing matches");
}

@test:Config {}
function testSearchRegistryRespectsMaxResults() {
    map<RegistryEntry> registry = {
        "datadog__get_datadog_metric": {name: "datadog__get_datadog_metric", description: "[datadog] Get a metric", inputSchema: {}},
        "datadog__get_datadog_trace": {name: "datadog__get_datadog_trace", description: "[datadog] Get a trace", inputSchema: {}},
        "datadog__search_datadog_monitors": {name: "datadog__search_datadog_monitors", description: "[datadog] Search monitors", inputSchema: {}},
        "datadog__search_datadog_logs": {name: "datadog__search_datadog_logs", description: "[datadog] Search logs", inputSchema: {}}
    };
    RegistryEntry[] results = searchRegistry(registry, "datadog", 2);
    test:assertTrue(results.length() <= 2, "should not exceed maxResults");
}

@test:Config {}
function testSearchRegistryBetterMatchRanksFirst() {
    map<RegistryEntry> registry = {
        "datadog__get_datadog_trace": {name: "datadog__get_datadog_trace", description: "[datadog] Get a full trace by ID", inputSchema: {}},
        "datadog__get_datadog_metric": {name: "datadog__get_datadog_metric", description: "[datadog] Get a metric time series", inputSchema: {}}
    };
    RegistryEntry[] results = searchRegistry(registry, "datadog metric", 5);
    test:assertEquals(results.length(), 2, "both tools should match");
    test:assertEquals(results[0].name, "datadog__get_datadog_metric", "higher-scoring tool must rank first");
}

@test:Config {}
function testSearchRegistryReturnsExactMaxResultsWhenAvailable() {
    map<RegistryEntry> registry = {
        "datadog__get_datadog_metric": {name: "datadog__get_datadog_metric", description: "[datadog] Get a metric", inputSchema: {}},
        "datadog__get_datadog_trace": {name: "datadog__get_datadog_trace", description: "[datadog] Get a trace", inputSchema: {}},
        "datadog__search_datadog_monitors": {name: "datadog__search_datadog_monitors", description: "[datadog] Search monitors", inputSchema: {}},
        "datadog__search_datadog_logs": {name: "datadog__search_datadog_logs", description: "[datadog] Search logs", inputSchema: {}}
    };
    RegistryEntry[] results = searchRegistry(registry, "datadog", 2);
    test:assertEquals(results.length(), 2, "should return exactly maxResults when enough tools match");
}

// ── handleDiscover (proxy-side discover_tools) ────────────────────────────────

@test:Config {}
function testHandleDiscoverEmptyQuery() {
    string result = handleDiscover({query: ""});
    test:assertTrue(result.includes("non-empty"), "empty query must return guidance mentioning 'non-empty'");
}

@test:Config {}
function testHandleDiscoverNoMatchReturnsHelp() {
    // Gibberish that cannot match any registered tool (topology or otherwise).
    string result = handleDiscover({query: "kubernetes fargate zzzzunknown"});
    test:assertTrue(result.includes("No tools matched"), "no-match must return the helpful fallback message");
}

@test:Config {}
function testHandleDiscoverMatchReturnsManifestJson() {
    // Seed a uniquely-named tool so the assertion is robust to whatever else is
    // in the shared module registry.
    registerTool({name: "splunk__zztest_probe", description: "[splunk] zztestunique diagnostic probe", inputSchema: {'type: "object"}});
    string result = handleDiscover({query: "zztestunique probe"});
    test:assertTrue(result.includes("\"tools\""), "match must return a JSON manifest bundle");
    test:assertTrue(result.includes("splunk__zztest_probe"), "manifest must include the matched tool name");
    test:assertTrue(result.includes("input_schema"), "manifest must expose input_schema for the agent to absorb");
}

// ── routeToolCall prefix stripping → local topology dispatch ──────────────────

@test:Config {}
function testRouteToolCallStripsTopologyPrefix() returns error? {
    // topology__list_runbooks must strip to list_runbooks and hit dispatchTool locally.
    string result = check routeToolCall("topology__list_runbooks", {});
    test:assertTrue(result.includes("disable-chaos"), "routed topology call must return runbook data");
}

@test:Config {}
function testRouteToolCallUnavailableBackendErrors() {
    // No backend is connected during unit tests, so a splunk__ call must surface
    // a clear 'unavailable' error rather than a null-dereference.
    string|error result = routeToolCall("splunk__splunk_run_query", {query: "index=*"});
    test:assertTrue(result is error, "call to an unconnected backend must return an error");
    if result is error {
        test:assertTrue(result.message().includes("unavailable"), "error must explain the backend is unavailable");
    }
}
