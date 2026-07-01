import ballerina/test;

// Pure function tests — no network required.
// Registry search + scoring now live in the mcp-proxy package; their
// tests moved there. The agent's remaining logic is prompt-building, the
// prefix split helper, config fallback, and absorbing discover_tools results.

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

// ── absorbDiscovered: folding proxy discover_tools results into activeTools ────

@test:Config {}
function testAbsorbDiscoveredAddsTools() {
    AnthropicTool[] activeTools = [];
    json bundle = {tools: [{name: "splunk__splunk_run_query", description: "[splunk] Run an SPL query", input_schema: {'type: "object"}}]};
    string result = absorbDiscovered(bundle.toJsonString(), activeTools);
    test:assertEquals(activeTools.length(), 1, "activeTools must grow after absorbing a manifest bundle");
    test:assertEquals(activeTools[0].name, "splunk__splunk_run_query");
    test:assertTrue(result.includes("Loaded"), "response must confirm tools were loaded");
    test:assertTrue(result.includes("splunk__splunk_run_query"), "response must name the loaded tool");
}

@test:Config {}
function testAbsorbDiscoveredPassThroughGuidance() {
    AnthropicTool[] activeTools = [];
    // The proxy returns plain guidance text (not a JSON bundle) for empty/no-match.
    string guidance = "Provide a non-empty query, e.g. \"Splunk logs\".";
    string result = absorbDiscovered(guidance, activeTools);
    test:assertEquals(result, guidance, "non-JSON guidance must pass through unchanged");
    test:assertEquals(activeTools.length(), 0, "guidance must not mutate activeTools");
}

@test:Config {}
function testAbsorbDiscoveredNoDuplication() {
    AnthropicTool tool = {name: "splunk__splunk_run_query", description: "[splunk] Run an SPL query", input_schema: {}};
    AnthropicTool[] activeTools = [tool]; // already present
    json bundle = {tools: [{name: "splunk__splunk_run_query", description: "[splunk] Run an SPL query", input_schema: {}}]};
    _ = absorbDiscovered(bundle.toJsonString(), activeTools);
    test:assertEquals(activeTools.length(), 1, "already-active tool must not be re-added");
}
