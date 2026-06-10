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
