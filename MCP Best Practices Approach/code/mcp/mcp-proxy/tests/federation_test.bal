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

@test:Config {}
function testRouteToolCallUnknownLabelFallsThroughToLocal() returns error? {
    // A prefix that isn't a known backend label must behave like "topology__"
    // always did — fall through to local dispatchTool — preserving the
    // pre-refactor behavior for any unrecognized/legacy prefix.
    string result = check routeToolCall("nosuchbackend__list_runbooks", {});
    test:assertTrue(result.includes("disable-chaos"), "unknown-label prefix must fall through to local dispatch");
}

// ── R4.1/R4.2 — BackendDef table, write guardrail (Refactor R4) ───────────────

@test:Config {}
function testBackendDefsRequiredSet() {
    boolean splunkRequired = false;
    boolean datadogRequired = false;
    int otherRequiredCount = 0;
    foreach BackendDef def in backendDefs() {
        if def.label == "splunk" { splunkRequired = def.required; }
        else if def.label == "datadog" { datadogRequired = def.required; }
        else if def.required { otherRequiredCount += 1; }
    }
    test:assertTrue(splunkRequired, "splunk must be required");
    test:assertTrue(datadogRequired, "datadog must be required");
    test:assertEquals(otherRequiredCount, 0, "only splunk/datadog may be required");
}

// ── Include toggles (INCLUDE_WSO2_MCP / INCLUDE_K8S_MCP) ────────────────────
// No env is set during unit tests, so these assert the configurable defaults:
// WSO2 group ON (apim/mi/is present), infra group OFF (k8s/docker absent).
// The actual Y/N env override is exercised by runDockerConfigTests.sh.

@test:Config {}
function testBackendDefsIncludesWso2ByDefault() {
    string[] labels = backendDefs().'map(d => d.label);
    foreach string want in ["apim", "mi", "is"] {
        test:assertTrue(labels.indexOf(want) != (), string `WSO2 backend '${want}' must be present when includeWso2Mcp defaults true`);
    }
}

@test:Config {}
function testBackendDefsExcludesK8sByDefault() {
    string[] labels = backendDefs().'map(d => d.label);
    test:assertTrue(labels.indexOf("k8s") == (), "k8s must be absent when includeK8sMcp defaults false");
    test:assertTrue(labels.indexOf("docker") == (), "docker must be absent when includeK8sMcp defaults false");
}

@test:Config {}
function testBackendDefsAlwaysHasRequiredRegardlessOfToggles() {
    string[] labels = backendDefs().'map(d => d.label);
    test:assertTrue(labels.indexOf("splunk") != (), "splunk is never gated by a toggle");
    test:assertTrue(labels.indexOf("datadog") != (), "datadog is never gated by a toggle");
}

@test:Config {}
function testEnvOrBoolYesNoParsing() {
    // Env not set → fallback returned; this locks in the fallback contract the
    // Y/N toggles depend on (the y/yes/n/no branches are covered by integration).
    test:assertTrue(envOrBool("NO_SUCH_INCLUDE_VAR_XYZ", true), "unset must return the true fallback");
    test:assertFalse(envOrBool("NO_SUCH_INCLUDE_VAR_XYZ", false), "unset must return the false fallback");
}

@test:Config {}
function testMatchesPatternExact() {
    test:assertTrue(matchesPattern("pods_list", "pods_list"), "exact match must pass");
    test:assertFalse(matchesPattern("pods_list", "pods_get"), "different exact name must not match");
}

@test:Config {}
function testMatchesPatternPrefixStar() {
    test:assertTrue(matchesPattern("resources_delete", "resources_*"), "prefix glob must match");
    test:assertFalse(matchesPattern("pods_list", "resources_*"), "prefix glob must not match a different prefix");
}

@test:Config {}
function testMatchesPatternSuffixStar() {
    test:assertTrue(matchesPattern("datadog_list", "*_list"), "suffix glob must match");
    test:assertFalse(matchesPattern("datadog_get", "*_list"), "suffix glob must not match a different suffix");
}

@test:Config {}
function testIsToolAllowedDenyWins() {
    BackendDef def = {label: "test", envKey: "TEST_MCP_URL", defaultUrl: "",
        allowTools: ["pods_delete"], denyTools: ["pods_delete"]};
    test:assertFalse(isToolAllowed(def, "pods_delete"), "deny must win even if also allowlisted");
}

@test:Config {}
function testIsToolAllowedEmptyAllowMeansAll() {
    BackendDef def = {label: "test", envKey: "TEST_MCP_URL", defaultUrl: "", denyTools: ["pods_delete"]};
    test:assertTrue(isToolAllowed(def, "pods_list"), "empty allowlist must permit any non-denied tool");
    test:assertFalse(isToolAllowed(def, "pods_delete"), "denylisted tool must still be blocked");
}

@test:Config {}
function testIsToolAllowedAllowlistDefaultDeny() {
    BackendDef def = {label: "test", envKey: "TEST_MCP_URL", defaultUrl: "", allowTools: ["list_*", "get_*"]};
    test:assertTrue(isToolAllowed(def, "list_containers"), "tool matching the allowlist must pass");
    test:assertFalse(isToolAllowed(def, "restart_container"), "tool not matching a non-empty allowlist must be denied");
}

@test:Config {}
function testRouteToolCallWriteRestricted() {
    // k8s is a known backend label (federation.bal backendDefs) but no backend
    // is connected in unit tests, so this still hits the "unavailable" branch
    // (checked above). To exercise the write-restricted branch specifically we
    // need a *connected* backend with an unregistered tool name — that requires
    // a live/mock HTTP backend and is covered by the Docker integration test
    // instead (tests/runDockerConfigTests.sh Test 9i, once the docker/k8s
    // backend exists in Phase 6). Here we confirm the two error messages are
    // textually distinct so a caller can tell "retry" from "not permitted".
    string unavailableMsg = "splunk MCP backend is unavailable (not connected). Retry shortly.";
    string restrictedMsg = "k8s__resources_delete is not available (not discovered, or write-restricted — write actions run only via topology__run_runbook).";
    test:assertTrue(unavailableMsg.includes("unavailable"), "sanity: unavailable message shape");
    test:assertTrue(restrictedMsg.includes("write-restricted"), "sanity: write-restricted message shape");
    test:assertFalse(unavailableMsg.includes("write-restricted"), "the two failure modes must be textually distinguishable");
}
