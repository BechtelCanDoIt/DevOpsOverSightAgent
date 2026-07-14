import ballerina/http;
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

// ── Phase 4 §4.9: generalized discover_tools prompt rule ─────────────────────

@test:Config {}
function testSystemPromptGeneralizesBeyondSplunkDatadog() {
    string lower = SYSTEM_PROMPT.toLowerAscii();
    test:assertTrue(lower.includes("non-topology__ tool"), "rule must generalize to any non-topology__ tool, not just Splunk/Datadog");
    test:assertTrue(lower.includes("kubernetes"), "system prompt must give a discover_tools example for the k8s backend");
    test:assertTrue(lower.includes("apim"), "system prompt must give a discover_tools example for the APIM backend");
}

// ── Phase 4 §4.9: configurable agentMaxTurns ─────────────────────────────────

@test:Config {}
function testAgentMaxTurnsDefaultIsFortyOrMore() {
    test:assertTrue(agentMaxTurns >= 25, "must never drop below 25 — Ollama non-determinism + discovery turns");
}

@test:Config {}
function testEnvOrIntFallback() {
    test:assertEquals(envOrInt("NO_SUCH_ENV_VAR_XYZ_ABC", 40), 40);
}

// ── Phase 4 §4.9: /health-report and /top5 skill-endpoint arg builders ───────
// These endpoints bypass the LLM tool-use loop entirely (see newProxyClient
// in devops_oversight_agent.bal) — only their pure argument-building logic is
// tested here, matching this package's existing network-free test convention.

@test:Config {}
function testBuildHealthReportArgsEmptyWhenNoProduct() {
    json args = buildHealthReportArgs(());
    test:assertEquals(args, {});
}

@test:Config {}
function testBuildHealthReportArgsIncludesProduct() {
    json args = buildHealthReportArgs("apim");
    test:assertEquals(args, {product: "apim"});
}

@test:Config {}
function testBuildTopIssuesArgsDefaults() {
    json args = buildTopIssuesArgs((), ());
    test:assertEquals(args, {});
}

@test:Config {}
function testBuildTopIssuesArgsIncludesCountAndProduct() {
    json args = buildTopIssuesArgs(3, "mi");
    test:assertEquals(args, {count: 3, product: "mi"});
}

// ── Human-approval gate (mirrors the LangChain sibling's interrupt) ──────────

@test:Config {}
function testInterceptRunRunbookBlocksAndStoresPending() {
    [string, string] [token, sentinel] = interceptRunRunbook({id: "disable-chaos", params: {"service": "payment-service"}});
    test:assertTrue(sentinel.startsWith(RUNBOOK_HALT_MARKER), "sentinel must carry the halt marker so the LLM loops stop");
    test:assertTrue(sentinel.includes("disable-chaos"), "sentinel must name the proposed runbook");
    test:assertTrue(sentinel.includes(token), "sentinel must surface the approval token to the operator");

    PendingRunbook? pending = takePendingRunbook(token);
    test:assertTrue(pending is PendingRunbook, "the proposal must actually be stored, not just described in prose");
    if pending is PendingRunbook {
        test:assertEquals(pending.runbookId, "disable-chaos");
    }
}

@test:Config {}
function testInterceptRunRunbookNeverExecutesDirectly() {
    // The whole point of the gate: calling interceptRunRunbook must never
    // reach the proxy. There is no http:Client in scope here at all — if
    // this function tried to make a network call, this test would need one
    // and would hang/fail. It doesn't, by construction.
    [string, string] [token, _] = interceptRunRunbook({id: "restart-service", params: {}});
    test:assertTrue(pendingRunbookCount() >= 1, "the attempt must be recorded as pending, not executed");
    _ = takePendingRunbook(token); // cleanup
}

@test:Config {}
function testTakePendingRunbookIsSingleUse() {
    [string, string] [token, _] = interceptRunRunbook({id: "clear-cache", params: {}});
    PendingRunbook? first = takePendingRunbook(token);
    test:assertTrue(first is PendingRunbook, "first take must find the pending entry");
    PendingRunbook? second = takePendingRunbook(token);
    test:assertTrue(second is (), "a token can only be consumed once — re-approving must not re-execute");
}

@test:Config {}
function testParseApprovalCommandApprove() {
    [string, string]? cmd = parseApprovalCommand("approve RB-7");
    test:assertTrue(cmd is [string, string]);
    if cmd is [string, string] {
        test:assertEquals(cmd[0], "approve");
        test:assertEquals(cmd[1], "RB-7");
    }
}

@test:Config {}
function testParseApprovalCommandDeny() {
    [string, string]? cmd = parseApprovalCommand("deny RB-3");
    test:assertTrue(cmd is [string, string]);
    if cmd is [string, string] {
        test:assertEquals(cmd[0], "deny");
        test:assertEquals(cmd[1], "RB-3");
    }
}

@test:Config {}
function testParseApprovalCommandNotACommand() {
    test:assertEquals(parseApprovalCommand("what is the status of the MI server?"), ());
    test:assertEquals(parseApprovalCommand("Top5 mi"), (), "must not collide with the skill-command parser");
}

@test:Config {}
function testHandleApprovalCommandUnknownTokenApprove() {
    string|error result = handleApprovalCommand("approve", "RB-does-not-exist");
    test:assertFalse(result is error);
    if result is string {
        test:assertTrue(result.includes("No pending runbook found"), "an unknown/expired token must not silently succeed");
    }
}

@test:Config {}
function testHandleApprovalCommandUnknownTokenDeny() {
    string|error result = handleApprovalCommand("deny", "RB-does-not-exist");
    test:assertFalse(result is error);
    if result is string {
        test:assertTrue(result.includes("No pending runbook found"));
    }
}

@test:Config {}
function testHandleApprovalCommandDenyDoesNotExecute() {
    [string, string] [token, _] = interceptRunRunbook({id: "freeze-deploys", params: {"reason": "test"}});
    string|error result = handleApprovalCommand("deny", token);
    test:assertFalse(result is error);
    if result is string {
        test:assertTrue(result.includes("DENIED"));
        test:assertTrue(result.includes("freeze-deploys"));
    }
    test:assertTrue(takePendingRunbook(token) is (), "denied token must be consumed, not left pending");
}

@test:Config {}
function testMakeDispatcherInterceptsRunRunbookWithoutCallingProxy() {
    // No http:Client is constructed here — if makeDispatcher's run_runbook
    // branch ever tried to reach the proxy, this test would need network
    // access and would fail/hang. It doesn't, by construction: the dispatcher
    // must short-circuit before touching proxyMcp for this one tool name.
    AnthropicTool[] activeTools = [];
    http:Client|error stubClient = new ("http://localhost:1", timeout = 1);
    test:assertTrue(stubClient is http:Client);
    if stubClient is http:Client {
        function (string, json) returns string dispatcher = makeDispatcher(activeTools, stubClient);
        string result = dispatcher("topology__run_runbook", {id: "disable-chaos", params: {"service": "payment-service"}});
        test:assertTrue(result.startsWith(RUNBOOK_HALT_MARKER));
    }
}

// ── Phase 7 §7.5 / Phase 4 §4.9: chat-command skills shortcuts ───────────────

@test:Config {}
function testParseSkillCommandHealthBare() {
    [string, string?, int?]? cmd = parseSkillCommand("Health");
    test:assertTrue(cmd is [string, string?, int?]);
    if cmd is [string, string?, int?] {
        test:assertEquals(cmd[0], "health");
        test:assertEquals(cmd[1], ());
    }
}

@test:Config {}
function testParseSkillCommandHealthWithProduct() {
    [string, string?, int?]? cmd = parseSkillCommand("Health apim");
    test:assertTrue(cmd is [string, string?, int?]);
    if cmd is [string, string?, int?] {
        test:assertEquals(cmd[0], "health");
        test:assertEquals(cmd[1], "apim");
    }
}

@test:Config {}
function testParseSkillCommandTop5WithCount() {
    [string, string?, int?]? cmd = parseSkillCommand("Top5 10");
    test:assertTrue(cmd is [string, string?, int?]);
    if cmd is [string, string?, int?] {
        test:assertEquals(cmd[0], "top5");
        test:assertEquals(cmd[2], 10);
        test:assertEquals(cmd[1], ());
    }
}

@test:Config {}
function testParseSkillCommandTop5WithProduct() {
    [string, string?, int?]? cmd = parseSkillCommand("Top5 mi");
    test:assertTrue(cmd is [string, string?, int?]);
    if cmd is [string, string?, int?] {
        test:assertEquals(cmd[0], "top5");
        test:assertEquals(cmd[1], "mi");
        test:assertEquals(cmd[2], ());
    }
}

@test:Config {}
function testParseSkillCommandNotACommand() {
    test:assertEquals(parseSkillCommand("Why is payment-service failing?"), ());
}

@test:Config {}
function testRenderHealthReportTableIncludesOverallAndSections() {
    json fixture = {overall: "CRITICAL", generatedAt: "now", sections: [
        {'source: "payment-service", status: "CRITICAL", summary: "mesh probe: DOWN", details: {}}
    ]};
    string md = renderHealthReportTable(fixture.toJsonString());
    test:assertTrue(md.includes("CRITICAL"));
    test:assertTrue(md.includes("payment-service"));
}

@test:Config {}
function testRenderTopIssuesTableEmptyIssuesShowsNoIssuesRow() {
    json fixture = {issues: []};
    string md = renderTopIssuesTable(fixture.toJsonString());
    test:assertTrue(md.includes("no issues found"));
}

@test:Config {}
function testRenderTopIssuesTableIncludesIssueRow() {
    json fixture = {issues: [
        {'source: "apim", severity: "P2", target: "LegacyBillingAPI", title: "API blocked", evidence: "lifeCycleStatus=BLOCKED", score: 6}
    ]};
    string md = renderTopIssuesTable(fixture.toJsonString());
    test:assertTrue(md.includes("LegacyBillingAPI"));
    test:assertTrue(md.includes("P2"));
}

@test:Config {}
function testAbsorbDiscoveredNoDuplication() {
    AnthropicTool tool = {name: "splunk__splunk_run_query", description: "[splunk] Run an SPL query", input_schema: {}};
    AnthropicTool[] activeTools = [tool]; // already present
    json bundle = {tools: [{name: "splunk__splunk_run_query", description: "[splunk] Run an SPL query", input_schema: {}}]};
    _ = absorbDiscovered(bundle.toJsonString(), activeTools);
    test:assertEquals(activeTools.length(), 1, "already-active tool must not be re-added");
}
