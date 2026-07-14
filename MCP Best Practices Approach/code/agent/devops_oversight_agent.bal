import ballerina/http;
import ballerina/lang.value;
import ballerina/log;

// ── Config — read from Config.toml; env vars override via envOrCfg ────────────
// The agent connects to ONE MCP server: the MCP Proxy. The proxy federates the
// Splunk / Datadog backends — the agent no longer opens clients to them.
configurable string ballerinaTopologyMcpUrl = "http://mcp-proxy:8290";

// Bumped from 30 (Phase 3/4) to absorb the extra discover_tools turns that
// come with more federated backends (Phase 6: apim/mi/is/k8s/docker). See
// todo/phase-4-agent.md §4.9 — do NOT reduce below 25 (Ollama non-determinism
// plus discovery turns mean some runs need up to 25 turns even pre-Phase-6).
configurable int agentMaxTurns = 40;

isolated function envOrCfg(string envKey, string fallback) returns string {
    string v = envOr(envKey, "");
    return v == "" ? fallback : v;
}

// ── Alert request shape ───────────────────────────────────────────────────────
type AlertRequest record {|
    string 'service;
    string severity = "P2";
    string description = "Incident detected";
    string id = "AGENT-001";
|};

// ── Chat request shape (WSO2 AMP Platform-Hosted agent protocol) ──────────────
type ChatRequest record {
    string message;
    string sessionId = "";
    string conversationId = "";
};

// ── Startup: LLM readiness check ─────────────────────────────────────────────
// Logs a clear error if the LLM backend is unreachable or misconfigured.
// For ollama: also attempts to pull the model if missing.
// Does not crash the service so /health remains reachable for diagnostics.
function init() {
    string provider = envOr("LLM_PROVIDER", "anthropic");
    error? readyErr = checkLlmReady();
    if readyErr is error {
        log:printError("LLM backend not ready — investigations will fail until this is resolved",
            'error = readyErr, provider = provider);
    } else {
        log:printInfo("LLM backend ready", provider = provider);
    }
}

// ── Listener on :8000 (AMP Platform-Hosted default) ─────────────────────────
// Long idle timeout: investigations can take minutes with many sequential tool calls.
listener http:Listener agentListener = new (8000, {timeout: 600});

service /health on agentListener {
    resource function get .() returns json => {status: "UP", 'service: "devops-oversight-agent"};
}

service /chat on agentListener {
    resource function post .(http:Request req) returns http:Response|error {
        json payload = check req.getJsonPayload();
        ChatRequest chatReq = check payload.cloneWithType(ChatRequest);
        log:printInfo("chat request received", sessionId = chatReq.sessionId);
        string response = check chat(chatReq.message);
        http:Response resp = new;
        resp.setJsonPayload({message: response});
        return resp;
    }
}

service /investigate on agentListener {
    resource function post .(http:Request req) returns http:Response|error {
        json payload = check req.getJsonPayload();
        AlertRequest alert = check payload.cloneWithType(AlertRequest);
        string summary = check investigate(alert);
        http:Response resp = new;
        resp.setJsonPayload({status: "investigated", alert_id: alert.id, summary: summary});
        return resp;
    }
}

// ── Skills passthrough: /health-report and /top5 (Phase 4 §4.9) ─────────────
// These bypass the LLM tool-use loop entirely — one direct MCP call through
// the proxy to topology__health_report / topology__top_issues. Deterministic,
// fast, and reachable even when the configured LLM backend has no valid
// credentials: init() above only logs a warning on a failed LLM readiness
// check, it never blocks the HTTP listener from starting or serving routes.

// Connects to the proxy and completes the initialize handshake, but skips
// tools/list — these endpoints call one known tool name directly and have no
// use for the full seed-tool manifest initMcp() builds for the LLM loop.
function newProxyClient() returns http:Client|error {
    string resolvedProxyUrl = envOrCfg("BALLERINA_TOPOLOGY_MCP_URL", ballerinaTopologyMcpUrl);
    http:Client proxyMcp = check new (resolvedProxyUrl, timeout = 30);
    check mcpInitialize(proxyMcp);
    return proxyMcp;
}

isolated function buildHealthReportArgs(string? product) returns json {
    if product is string && product.trim() != "" {
        return {product: product};
    }
    return {};
}

isolated function buildTopIssuesArgs(int? count, string? product) returns json {
    map<json> args = {};
    if count is int {
        args["count"] = count;
    }
    if product is string && product.trim() != "" {
        args["product"] = product;
    }
    return args;
}

service /health\-report on agentListener {
    resource function get .(string? product) returns http:Response|error {
        http:Client proxyMcp = check newProxyClient();
        McpToolResult result = check mcpCallTool(proxyMcp, "topology__health_report", buildHealthReportArgs(product), 1);
        http:Response resp = new;
        resp.setHeader("Content-Type", "application/json");
        resp.setTextPayload(result.text);
        return resp;
    }
}

service /top5 on agentListener {
    resource function get .(string? product, int? count) returns http:Response|error {
        http:Client proxyMcp = check newProxyClient();
        McpToolResult result = check mcpCallTool(proxyMcp, "topology__top_issues", buildTopIssuesArgs(count, product), 1);
        http:Response resp = new;
        resp.setHeader("Content-Type", "application/json");
        resp.setTextPayload(result.text);
        return resp;
    }
}

service /webhook on agentListener {
    // Datadog webhook-style alert
    resource function post alert(http:Request req) returns http:Response|error {
        json payload = check req.getJsonPayload();
        AlertRequest alert = {
            'service: payload.'service is () ? "unknown" : (check payload.'service).toString(),
            severity: payload.severity is () ? "P2" : (check payload.severity).toString(),
            description: payload.description is () ? (payload.title is () ? "Alert" : (check payload.title).toString()) : (check payload.description).toString(),
            id: payload.id is () ? "webhook" : (check payload.id).toString()
        };
        string summary = check investigate(alert);
        http:Response resp = new;
        resp.setJsonPayload({status: "investigated", summary: summary});
        return resp;
    }
}

// ── Lazy tool loading ─────────────────────────────────────────────────────────
// The MCP Proxy owns federation now. On turn 1 the agent seeds only what the
// proxy advertises in tools/list: discover_tools + the topology tools. Splunk
// and Datadog tools are revealed by calling the proxy's discover_tools, whose
// result carries their manifests — absorbDiscovered() folds them into the
// live activeTools set so the LLM can call them on the next turn.

// Fold a discover_tools result into activeTools. The proxy returns either a
// guidance string (empty/no-match) — passed through unchanged — or a JSON
// bundle {"tools":[{name,description,input_schema},...]} which we absorb.
// activeTools is a reference — push() here is visible to the LLM loop.
function absorbDiscovered(string resultText, AnthropicTool[] activeTools) returns string {
    json|error parsed = value:fromJsonString(resultText);
    if parsed is error {
        return resultText; // guidance text, not a manifest bundle
    }
    json|error toolsField = parsed.tools;
    if !(toolsField is json[]) {
        return resultText;
    }
    json[] discovered = toolsField;
    if discovered.length() == 0 {
        return resultText;
    }
    string resultMsg = "";
    int idx = 0;
    foreach json t in discovered {
        AnthropicTool|error tool = t.cloneWithType(AnthropicTool);
        if tool is error {
            continue;
        }
        boolean alreadyActive = false;
        foreach AnthropicTool existing in activeTools {
            if existing.name == tool.name {
                alreadyActive = true;
                break;
            }
        }
        if !alreadyActive {
            activeTools.push(tool);
        }
        if idx > 0 {
            resultMsg += "\n";
        }
        resultMsg += string `• ${tool.name}: ${tool.description}`;
        idx += 1;
    }
    return string `Loaded ${discovered.length()} tool(s) — now callable:\n${resultMsg}`;
}

// ── MCP initialisation ────────────────────────────────────────────────────────

// Connect to the MCP Proxy and fetch its pre-seed tool list once.
// Returns: the proxy client + the seed tools (discover_tools + topology tools).
function initMcp() returns [http:Client, AnthropicTool[]]|error {
    string resolvedProxyUrl = envOrCfg("BALLERINA_TOPOLOGY_MCP_URL", ballerinaTopologyMcpUrl);
    http:Client proxyMcp = check new (resolvedProxyUrl, timeout = 30);

    error? proxyInit = mcpInitialize(proxyMcp);
    if proxyInit is error { log:printWarn("MCP Proxy init failed", 'error = proxyInit); }

    AnthropicTool[] seedTools = [];
    McpToolDef[]|error tools = mcpListTools(proxyMcp);
    if tools is McpToolDef[] {
        foreach McpToolDef t in tools {
            // The proxy already namespaces and tags names/descriptions.
            seedTools.push({name: t.name, description: t.description, input_schema: t.inputSchema});
        }
    } else {
        log:printWarn("MCP Proxy tools/list failed — agent has no tools", 'error = tools);
    }
    return [proxyMcp, seedTools];
}

// Build a dispatcher closure. Every tool call is forwarded to the proxy, which
// routes it to the right backend. discover_tools results are absorbed into the
// live activeTools set. activeTools is a reference — push() is visible upstream.
//
// topology__run_runbook is the one exception: it is NEVER forwarded to the
// proxy from here. See approval.bal — this is the hard human-approval gate,
// and this line is the only place in the codebase that decides whether a
// tool call reaches the proxy's real execution path. A model cannot bypass
// it by retrying, rephrasing, or claiming success.
function makeDispatcher(
    AnthropicTool[] activeTools,
    http:Client proxyMcp
) returns function (string, json) returns string {
    return function(string toolName, json args) returns string {
        if toolName == "topology__run_runbook" {
            [string, string] [_, sentinel] = interceptRunRunbook(args);
            return sentinel;
        }
        McpToolResult|error result = mcpCallTool(proxyMcp, toolName, args, 99);
        if result is error { return string `Tool error: ${result.message()}`; }
        if toolName == "discover_tools" {
            return absorbDiscovered(result.text, activeTools);
        }
        return result.text;
    };
}

// ── Chat-command skills shortcuts (Phase 7 §7.5 / Phase 4 §4.9) ─────────────
// "Health" / "Health apim" / "Top5" / "Top5 10" / "Top5 mi" bypass the LLM
// loop entirely — same underlying calls as /health-report and /top5, just
// reachable from the chat surface too, rendered as a markdown table.

// Returns [kind, product, count] when the message is a recognized skill
// command, () otherwise. "Top5 <N>" sets count; "Top5 <word>" sets product.
isolated function parseSkillCommand(string message) returns [string, string?, int?]? {
    string trimmed = message.trim();
    string lower = trimmed.toLowerAscii();
    if lower == "health" {
        return ["health", (), ()];
    }
    if lower.startsWith("health ") {
        string rest = trimmed.substring(7).trim();
        return ["health", rest == "" ? () : rest, ()];
    }
    if lower == "top5" {
        return ["top5", (), ()];
    }
    if lower.startsWith("top5 ") {
        string rest = trimmed.substring(5).trim();
        if rest == "" {
            return ["top5", (), ()];
        }
        int|error asCount = int:fromString(rest);
        if asCount is int {
            return ["top5", (), asCount];
        }
        return ["top5", rest, ()];
    }
    return ();
}

isolated function fieldOrDash(json obj, string fieldName) returns string {
    if obj is map<json> {
        json? v = obj[fieldName];
        if v is string {
            return v;
        }
        if v is int || v is boolean {
            return v.toString();
        }
    }
    return "—";
}

function renderHealthReportTable(string jsonText) returns string {
    json|error parsed = value:fromJsonString(jsonText);
    if parsed is error {
        return jsonText;
    }
    string overall = fieldOrDash(parsed, "overall");
    string md = string `**Overall: ${overall}**` + "\n\n| Source | Status | Summary |\n|---|---|---|\n";
    json|error sectionsF = parsed is map<json> ? parsed["sections"] : ();
    if sectionsF is json[] {
        foreach json s in sectionsF {
            md += string `| ${fieldOrDash(s, "source")} | ${fieldOrDash(s, "status")} | ${fieldOrDash(s, "summary")} |` + "\n";
        }
    }
    return md;
}

function renderTopIssuesTable(string jsonText) returns string {
    json|error parsed = value:fromJsonString(jsonText);
    if parsed is error {
        return jsonText;
    }
    string md = "| Severity | Source | Target | Title | Score |\n|---|---|---|---|---|\n";
    json|error issuesF = parsed is map<json> ? parsed["issues"] : ();
    if issuesF is json[] {
        if issuesF.length() == 0 {
            return md + "| — | — | no issues found | — | — |\n";
        }
        foreach json i in issuesF {
            md += string `| ${fieldOrDash(i, "severity")} | ${fieldOrDash(i, "source")} | ${fieldOrDash(i, "target")} | ${fieldOrDash(i, "title")} | ${fieldOrDash(i, "score")} |` + "\n";
        }
    }
    return md;
}

function runSkillCommand(string kind, string? product, int? count) returns string|error {
    http:Client proxyMcp = check newProxyClient();
    if kind == "health" {
        McpToolResult result = check mcpCallTool(proxyMcp, "topology__health_report", buildHealthReportArgs(product), 1);
        return renderHealthReportTable(result.text);
    }
    McpToolResult result = check mcpCallTool(proxyMcp, "topology__top_issues", buildTopIssuesArgs(count, product), 1);
    return renderTopIssuesTable(result.text);
}

// ── Human-approval gate: "approve <token>" / "deny <token>" ─────────────────
// The ONLY code path that ever calls the proxy's real topology__run_runbook.
// makeDispatcher's interceptRunRunbook (approval.bal) guarantees the LLM can
// never reach it directly — this function is reachable only from a chat
// message matching parseApprovalCommand, checked before the LLM ever sees it.
function handleApprovalCommand(string action, string token) returns string|error {
    PendingRunbook? pending = takePendingRunbook(token);
    if pending is () {
        return string `No pending runbook found for token "${token}" (already resolved, denied, or never issued).`;
    }
    if action == "deny" {
        return string `Runbook "${pending.runbookId}" (token ${token}) was DENIED by the operator. No action was taken.`;
    }
    http:Client proxyMcp = check newProxyClient();
    McpToolResult|error result = mcpCallTool(proxyMcp, "topology__run_runbook", {id: pending.runbookId, params: pending.params}, 1);
    if result is error {
        return string `Approved runbook "${pending.runbookId}" (token ${token}) but execution failed: ${result.message()}`;
    }
    return string `Runbook "${pending.runbookId}" (token ${token}) APPROVED and executed:` + "\n" + result.text;
}

// ── Core chat function ────────────────────────────────────────────────────────

function chat(string userMessage) returns string|error {
    [string, string]? approvalCmd = parseApprovalCommand(userMessage);
    if approvalCmd is [string, string] {
        return check handleApprovalCommand(approvalCmd[0], approvalCmd[1]);
    }

    [string, string?, int?]? skillCmd = parseSkillCommand(userMessage);
    if skillCmd is [string, string?, int?] {
        return check runSkillCommand(skillCmd[0], skillCmd[1], skillCmd[2]);
    }

    [http:Client, AnthropicTool[]] mcpInit = check initMcp();
    http:Client proxyMcp = mcpInit[0];
    // Seed set from the proxy: discover_tools + topology tools. Splunk and
    // Datadog tools are added dynamically via discover_tools.
    AnthropicTool[] activeTools = mcpInit[1];

    function (string, json) returns string dispatcher = makeDispatcher(activeTools, proxyMcp);
    return check runConfiguredLlm(SYSTEM_PROMPT, userMessage, activeTools, dispatcher, envOrInt("AGENT_MAX_TURNS", agentMaxTurns));
}

// ── Core investigation function ───────────────────────────────────────────────

function investigate(AlertRequest alert) returns string|error {
    log:printInfo("starting investigation", 'service = alert.'service, severity = alert.severity);

    [http:Client, AnthropicTool[]] mcpInit = check initMcp();
    http:Client proxyMcp = mcpInit[0];
    AnthropicTool[] activeTools = mcpInit[1];

    function (string, json) returns string dispatcher = makeDispatcher(activeTools, proxyMcp);
    string userPrompt = buildInvestigationPrompt(alert.'service, alert.severity, alert.description, alert.id);
    string summary = check runConfiguredLlm(SYSTEM_PROMPT, userPrompt, activeTools, dispatcher, envOrInt("AGENT_MAX_TURNS", agentMaxTurns));
    log:printInfo("investigation complete", 'service = alert.'service);
    return summary;
}

// Split a string on the first occurrence of a delimiter.
isolated function splitOnFirst(string s, string delimiter) returns string[]|error {
    int? idx = s.indexOf(delimiter);
    if idx is () { return error(string `Delimiter '${delimiter}' not found in '${s}'`); }
    return [s.substring(0, idx), s.substring(idx + delimiter.length())];
}
