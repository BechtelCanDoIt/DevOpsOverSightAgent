import ballerina/http;
import ballerina/lang.value;
import ballerina/log;

// ── Config — read from Config.toml; env vars override via envOrCfg ────────────
// The agent connects to ONE MCP server: the MCP Proxy. The proxy federates the
// Splunk / Datadog backends — the agent no longer opens clients to them.
configurable string ballerinaTopologyMcpUrl = "http://mcp-proxy:8290";

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
function makeDispatcher(
    AnthropicTool[] activeTools,
    http:Client proxyMcp
) returns function (string, json) returns string {
    return function(string toolName, json args) returns string {
        McpToolResult|error result = mcpCallTool(proxyMcp, toolName, args, 99);
        if result is error { return string `Tool error: ${result.message()}`; }
        if toolName == "discover_tools" {
            return absorbDiscovered(result.text, activeTools);
        }
        return result.text;
    };
}

// ── Core chat function ────────────────────────────────────────────────────────

function chat(string userMessage) returns string|error {
    [http:Client, AnthropicTool[]] mcpInit = check initMcp();
    http:Client proxyMcp = mcpInit[0];
    // Seed set from the proxy: discover_tools + topology tools. Splunk and
    // Datadog tools are added dynamically via discover_tools.
    AnthropicTool[] activeTools = mcpInit[1];

    function (string, json) returns string dispatcher = makeDispatcher(activeTools, proxyMcp);
    return check runConfiguredLlm(SYSTEM_PROMPT, userMessage, activeTools, dispatcher, 30);
}

// ── Core investigation function ───────────────────────────────────────────────

function investigate(AlertRequest alert) returns string|error {
    log:printInfo("starting investigation", 'service = alert.'service, severity = alert.severity);

    [http:Client, AnthropicTool[]] mcpInit = check initMcp();
    http:Client proxyMcp = mcpInit[0];
    AnthropicTool[] activeTools = mcpInit[1];

    function (string, json) returns string dispatcher = makeDispatcher(activeTools, proxyMcp);
    string userPrompt = buildInvestigationPrompt(alert.'service, alert.severity, alert.description, alert.id);
    string summary = check runConfiguredLlm(SYSTEM_PROMPT, userPrompt, activeTools, dispatcher, 30);
    log:printInfo("investigation complete", 'service = alert.'service);
    return summary;
}

// Split a string on the first occurrence of a delimiter.
isolated function splitOnFirst(string s, string delimiter) returns string[]|error {
    int? idx = s.indexOf(delimiter);
    if idx is () { return error(string `Delimiter '${delimiter}' not found in '${s}'`); }
    return [s.substring(0, idx), s.substring(idx + delimiter.length())];
}
