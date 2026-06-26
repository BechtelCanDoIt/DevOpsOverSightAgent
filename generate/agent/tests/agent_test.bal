import ballerina/test;

// Pure function tests — no network required.

@test:Config {}
function testBuildInvestigationPromptIncludesService() {
    string prompt = buildInvestigationPrompt("payment-service", "P1", "502 errors", "INC-001");
    test:assertTrue(prompt.includes("payment-service"), "prompt must include service name");
    test:assertTrue(prompt.includes("P1"), "prompt must include severity");
    test:assertTrue(prompt.includes("502 errors"), "prompt must include description");
    test:assertTrue(prompt.includes("INC-001"), "prompt must include alert id");
}

@test:Config {}
function testBuildInvestigationPromptMissingFieldsHandled() {
    string prompt = buildInvestigationPrompt("", "", "", "");
    test:assertFalse(prompt == "", "prompt must not be empty even with empty fields");
}

@test:Config {}
function testSystemPromptMentionsAllThreeMcps() {
    test:assertTrue(SYSTEM_PROMPT.includes("Splunk"), "system prompt must mention Splunk");
    test:assertTrue(SYSTEM_PROMPT.includes("Datadog"), "system prompt must mention Datadog");
    test:assertTrue(SYSTEM_PROMPT.includes("Topology"), "system prompt must mention Topology");
}

@test:Config {}
function testSystemPromptHasRunbookGuardrail() {
    test:assertTrue(SYSTEM_PROMPT.toLowerAscii().includes("runbook"), "system prompt must mention runbook");
    test:assertTrue(SYSTEM_PROMPT.toLowerAscii().includes("propose"), "system prompt must include propose-before-act guardrail");
}

@test:Config {}
function testSplitOnFirstHappyPath() {
    string[]|error parts = splitOnFirst("splunk__splunk_run_query", "__");
    test:assertFalse(parts is error, "split must succeed");
    if parts is string[] {
        test:assertEquals(parts[0], "splunk");
        test:assertEquals(parts[1], "splunk_run_query");
    }
}

@test:Config {}
function testSplitOnFirstDoubleSeparator() {
    string[]|error parts = splitOnFirst("topology__correlate_trace", "__");
    test:assertFalse(parts is error);
    if parts is string[] {
        test:assertEquals(parts[0], "topology");
        test:assertEquals(parts[1], "correlate_trace");
    }
}

@test:Config {}
function testSplitOnFirstNotFound() {
    string[]|error parts = splitOnFirst("no-separator-here", "__");
    test:assertTrue(parts is error, "must error when delimiter not found");
}

@test:Config {}
function testEnvOrCfgFallback() {
    // With no env var set for a nonsense key, should return fallback.
    string result = envOrCfg("NO_SUCH_ENV_VAR_XYZ_ABC", "my-fallback");
    test:assertEquals(result, "my-fallback");
}

@test:Config {}
function testSystemPromptMentionsDiscoverTools() {
    test:assertTrue(SYSTEM_PROMPT.includes("discover_tools"), "system prompt must mention discover_tools for lazy loading");
}

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
    // "monitors" prefix "moni" matches "monitors" in description
    int score = scoreToolMatch("datadog__search_datadog_monitors", "[datadog] Search monitors by name or tag", "datadog monitors alerts");
    test:assertTrue(score > 0, "should match via 'datadog' exact and 'moni' prefix");
}

@test:Config {}
function testScoreToolMatchShortWordsIgnored() {
    // Single-char and two-char words must not contribute to score
    int score = scoreToolMatch("topology__list_services", "[topology] List all 7 mesh services", "a of in");
    test:assertEquals(score, 0, "words of length <= 2 must be ignored");
}

@test:Config {}
function testSearchRegistryRanksTopMatch() {
    map<AnthropicTool> registry = {
        "splunk__splunk_run_query": {name: "splunk__splunk_run_query", description: "[splunk] Run an SPL query", input_schema: {}},
        "topology__lookup_service": {name: "topology__lookup_service", description: "[topology] Look up a service", input_schema: {}},
        "datadog__get_datadog_metric": {name: "datadog__get_datadog_metric", description: "[datadog] Get a metric time series", input_schema: {}}
    };
    AnthropicTool[] results = searchRegistry(registry, "splunk query logs", 5);
    test:assertTrue(results.length() > 0, "should find at least one tool");
    test:assertEquals(results[0].name, "splunk__splunk_run_query", "top result should be the splunk query tool");
}

@test:Config {}
function testSearchRegistryEmptyOnNoMatch() {
    map<AnthropicTool> registry = {
        "topology__lookup_service": {name: "topology__lookup_service", description: "[topology] Look up a service", input_schema: {}}
    };
    AnthropicTool[] results = searchRegistry(registry, "kubernetes fargate lambda zzzunknown", 5);
    test:assertEquals(results.length(), 0, "should return empty array when nothing matches");
}

@test:Config {}
function testSearchRegistryRespectsMaxResults() {
    map<AnthropicTool> registry = {
        "datadog__get_datadog_metric": {name: "datadog__get_datadog_metric", description: "[datadog] Get a metric", input_schema: {}},
        "datadog__get_datadog_trace": {name: "datadog__get_datadog_trace", description: "[datadog] Get a trace", input_schema: {}},
        "datadog__search_datadog_monitors": {name: "datadog__search_datadog_monitors", description: "[datadog] Search monitors", input_schema: {}},
        "datadog__search_datadog_logs": {name: "datadog__search_datadog_logs", description: "[datadog] Search logs", input_schema: {}}
    };
    AnthropicTool[] results = searchRegistry(registry, "datadog", 2);
    test:assertTrue(results.length() <= 2, "should not exceed maxResults");
}
