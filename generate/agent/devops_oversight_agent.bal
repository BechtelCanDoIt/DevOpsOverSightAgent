import ballerina/http;
import ballerina/log;

// ── Config — read from Config.toml; env vars override via envOrCfg ────────────
configurable string splunkMcpUrl = "http://splunk-mock-mcp:8400";
configurable string datadogMcpUrl = "http://datadog-mock-mcp:8401";
configurable string ballerinaTopologyMcpUrl = "http://mcp-server:8290";

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
// Topology tools are pre-seeded in every context (bounded, custom, always needed).
// Splunk and Datadog tools are loaded on demand via discover_tools — this keeps
// context small now and scales cleanly when the real vendor MCPs (50+ tools each)
// replace the mocks.

final AnthropicTool DISCOVER_TOOL = {
    name: "discover_tools",
    description: "Search for tools by capability and add their schemas to your context. Call this before using any Splunk or Datadog tool. Examples: \"Splunk log query\", \"Datadog metric trace APM\", \"Datadog monitor error tracking\".",
    input_schema: {
        "type": "object",
        "properties": {
            "query": {
                "type": "string",
                "description": "Natural language description of the capability needed (e.g. \"Splunk logs query\", \"Datadog metric time series\", \"Datadog trace APM spans\")"
            }
        },
        "required": ["query"]
    }
};

// Score how well a tool matches a query. Words > 2 chars: exact match = +2,
// 4-char prefix match (handles plurals/stems) = +1 for words length >= 5.
isolated function scoreToolMatch(string name, string description, string query) returns int {
    string haystack = string `${name} ${description}`.toLowerAscii();
    int score = 0;
    string remaining = query.toLowerAscii();
    while remaining.length() > 0 {
        int? spaceIdx = remaining.indexOf(" ");
        string word;
        if spaceIdx is int {
            word = remaining.substring(0, spaceIdx);
            remaining = remaining.substring(spaceIdx + 1);
        } else {
            word = remaining;
            remaining = "";
        }
        if word.length() <= 2 {
            continue;
        }
        if haystack.includes(word) {
            score += 2;
        } else if word.length() >= 5 && haystack.includes(word.substring(0, 4)) {
            score += 1;
        }
    }
    return score;
}

// Return up to maxResults tools from registry ranked by query relevance.
// Returns empty array when nothing scores > 0.
function searchRegistry(map<AnthropicTool> registry, string query, int maxResults) returns AnthropicTool[] {
    [string, int][] scored = [];
    foreach string k in registry.keys() {
        AnthropicTool t = registry.get(k);
        int s = scoreToolMatch(t.name, t.description, query);
        if s > 0 {
            scored.push([k, s]);
        }
    }
    // Selection sort descending by score (N <= 21, cost is negligible)
    int sz = scored.length();
    int ii = 0;
    while ii < sz - 1 {
        int bestIdx = ii;
        int jj = ii + 1;
        while jj < sz {
            if scored[jj][1] > scored[bestIdx][1] {
                bestIdx = jj;
            }
            jj += 1;
        }
        if bestIdx != ii {
            [string, int] tmp = scored[ii];
            scored[ii] = scored[bestIdx];
            scored[bestIdx] = tmp;
        }
        ii += 1;
    }
    AnthropicTool[] result = [];
    int lim = scored.length() < maxResults ? scored.length() : maxResults;
    int idx = 0;
    while idx < lim {
        result.push(registry.get(scored[idx][0]));
        idx += 1;
    }
    return result;
}

// ── MCP initialisation ────────────────────────────────────────────────────────

// Connect to all 3 MCP servers and fetch their tool lists once.
// Returns: splunkMcp, datadogMcp, topologyMcp, full registry, topology tools (pre-seeded).
function initMcp() returns [http:Client, http:Client, http:Client, map<AnthropicTool>, AnthropicTool[]]|error {
    string resolvedSplunkUrl = envOrCfg("SPLUNK_MCP_URL", splunkMcpUrl);
    string resolvedDatadogUrl = envOrCfg("DATADOG_MCP_URL", datadogMcpUrl);
    string resolvedTopologyUrl = envOrCfg("BALLERINA_TOPOLOGY_MCP_URL", ballerinaTopologyMcpUrl);

    http:Client splunkMcp = check new (resolvedSplunkUrl, timeout = 30);
    http:Client datadogMcp = check new (resolvedDatadogUrl, timeout = 30);
    http:Client topologyMcp = check new (resolvedTopologyUrl, timeout = 30);

    error? splunkInit = mcpInitialize(splunkMcp);
    error? ddInit = mcpInitialize(datadogMcp);
    error? topInit = mcpInitialize(topologyMcp);

    if splunkInit is error { log:printWarn("Splunk MCP init failed", 'error = splunkInit); }
    if ddInit is error { log:printWarn("Datadog MCP init failed", 'error = ddInit); }
    if topInit is error { log:printWarn("Topology MCP init failed", 'error = topInit); }

    map<AnthropicTool> registry = {};
    AnthropicTool[] topologyTools = [];

    if splunkInit !is error {
        McpToolDef[]|error splunkTools = mcpListTools(splunkMcp);
        if splunkTools is McpToolDef[] {
            foreach McpToolDef t in splunkTools {
                string n = string `splunk__${t.name}`;
                registry[n] = {name: n, description: string `[splunk] ${t.description}`, input_schema: t.inputSchema};
            }
        }
    }
    if ddInit !is error {
        McpToolDef[]|error ddTools = mcpListTools(datadogMcp);
        if ddTools is McpToolDef[] {
            foreach McpToolDef t in ddTools {
                string n = string `datadog__${t.name}`;
                registry[n] = {name: n, description: string `[datadog] ${t.description}`, input_schema: t.inputSchema};
            }
        }
    }
    if topInit !is error {
        McpToolDef[]|error topTools = mcpListTools(topologyMcp);
        if topTools is McpToolDef[] {
            foreach McpToolDef t in topTools {
                string n = string `topology__${t.name}`;
                AnthropicTool tool = {name: n, description: string `[topology] ${t.description}`, input_schema: t.inputSchema};
                registry[n] = tool;
                topologyTools.push(tool);
            }
        }
    }
    return [splunkMcp, datadogMcp, topologyMcp, registry, topologyTools];
}

// Build a dispatcher closure. Routes discover_tools calls (expands activeTools in place)
// and real tool calls to the correct MCP client.
// activeTools is a reference — push() inside the closure is visible to the caller.
function makeDispatcher(
    AnthropicTool[] activeTools,
    map<AnthropicTool> registry,
    http:Client splunkMcp,
    http:Client datadogMcp,
    http:Client topologyMcp
) returns function (string, json) returns string {
    return function(string toolName, json args) returns string {
        if toolName == "discover_tools" {
            json|error queryField = args.query;
            string query = queryField is json ? queryField.toString() : "";
            if query == "" {
                return "Provide a non-empty query, e.g. \"Splunk logs\", \"Datadog metric trace\", \"topology runbook\".";
            }
            AnthropicTool[] found = searchRegistry(registry, query, 5);
            if found.length() == 0 {
                return string `No tools matched "${query}". Try: "Splunk logs query", "Datadog metric trace APM monitor", or "topology service dependency runbook correlate".`;
            }
            string resultMsg = "";
            int idx = 0;
            foreach AnthropicTool t in found {
                boolean alreadyActive = false;
                foreach AnthropicTool existing in activeTools {
                    if existing.name == t.name {
                        alreadyActive = true;
                        break;
                    }
                }
                if !alreadyActive {
                    activeTools.push(t);
                }
                if idx > 0 {
                    resultMsg += "\n";
                }
                resultMsg += string `• ${t.name}: ${t.description}`;
                idx += 1;
            }
            return string `Loaded ${found.length()} tool(s) — now callable:\n${resultMsg}`;
        }

        // Route by real tool name (strip "<prefix>__"). Robust to wrong namespace prefix.
        string realName = toolName;
        int? sep = toolName.indexOf("__");
        if sep is int {
            realName = toolName.substring(sep + 2);
        }
        http:Client targetClient;
        if realName.startsWith("splunk_") {
            targetClient = splunkMcp;
        } else if realName.includes("datadog") || realName.startsWith("apm_") {
            targetClient = datadogMcp;
        } else {
            targetClient = topologyMcp;
        }
        McpToolResult|error result = mcpCallTool(targetClient, realName, args, 99);
        if result is error { return string `Tool error: ${result.message()}`; }
        return result.text;
    };
}

// ── Core chat function ────────────────────────────────────────────────────────

function chat(string userMessage) returns string|error {
    [http:Client, http:Client, http:Client, map<AnthropicTool>, AnthropicTool[]] mcpInit = check initMcp();
    http:Client splunkMcp = mcpInit[0];
    http:Client datadogMcp = mcpInit[1];
    http:Client topologyMcp = mcpInit[2];
    map<AnthropicTool> registry = mcpInit[3];
    AnthropicTool[] topologyTools = mcpInit[4];

    // Seed: discover_tools + all topology tools (bounded, always needed).
    // Splunk and Datadog tools are added dynamically via discover_tools.
    AnthropicTool[] activeTools = [DISCOVER_TOOL];
    foreach AnthropicTool t in topologyTools {
        activeTools.push(t);
    }

    function (string, json) returns string dispatcher =
        makeDispatcher(activeTools, registry, splunkMcp, datadogMcp, topologyMcp);
    return check runConfiguredLlm(SYSTEM_PROMPT, userMessage, activeTools, dispatcher, 30);
}

// ── Core investigation function ───────────────────────────────────────────────

function investigate(AlertRequest alert) returns string|error {
    log:printInfo("starting investigation", 'service = alert.'service, severity = alert.severity);

    [http:Client, http:Client, http:Client, map<AnthropicTool>, AnthropicTool[]] mcpInit = check initMcp();
    http:Client splunkMcp = mcpInit[0];
    http:Client datadogMcp = mcpInit[1];
    http:Client topologyMcp = mcpInit[2];
    map<AnthropicTool> registry = mcpInit[3];
    AnthropicTool[] topologyTools = mcpInit[4];

    AnthropicTool[] activeTools = [DISCOVER_TOOL];
    foreach AnthropicTool t in topologyTools {
        activeTools.push(t);
    }

    function (string, json) returns string dispatcher =
        makeDispatcher(activeTools, registry, splunkMcp, datadogMcp, topologyMcp);
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
