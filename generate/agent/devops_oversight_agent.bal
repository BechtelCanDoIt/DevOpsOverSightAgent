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
// Long idle timeout: local-Ollama investigations run many sequential tool-call turns
// and can take minutes; the default would abort the response mid-investigation.
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

// ── Core chat function ────────────────────────────────────────────────────────

function chat(string userMessage) returns string|error {
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

    AnthropicTool[] allTools = [];
    if splunkInit !is error {
        McpToolDef[]|error splunkTools = mcpListTools(splunkMcp);
        if splunkTools is McpToolDef[] {
            foreach McpToolDef t in splunkTools {
                allTools.push({name: string `splunk__${t.name}`, description: string `[splunk] ${t.description}`, input_schema: t.inputSchema});
            }
        }
    }
    if ddInit !is error {
        McpToolDef[]|error ddTools = mcpListTools(datadogMcp);
        if ddTools is McpToolDef[] {
            foreach McpToolDef t in ddTools {
                allTools.push({name: string `datadog__${t.name}`, description: string `[datadog] ${t.description}`, input_schema: t.inputSchema});
            }
        }
    }
    if topInit !is error {
        McpToolDef[]|error topTools = mcpListTools(topologyMcp);
        if topTools is McpToolDef[] {
            foreach McpToolDef t in topTools {
                allTools.push({name: string `topology__${t.name}`, description: string `[topology] ${t.description}`, input_schema: t.inputSchema});
            }
        }
    }

    function (string, json) returns string dispatcher = function(string toolName, json args) returns string {
        // Route by the REAL tool name (strip any "<prefix>__"). Robust to smaller models
        // emitting the wrong namespace prefix, e.g. topology__search_datadog_monitors.
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

    return check runConfiguredLlm(SYSTEM_PROMPT, userMessage, allTools, dispatcher, 12);
}

// ── Core investigation function ───────────────────────────────────────────────

function investigate(AlertRequest alert) returns string|error {
    log:printInfo("starting investigation", 'service = alert.'service, severity = alert.severity);

    // Connect to MCP servers (use env-override URLs).
    string resolvedSplunkUrl = envOrCfg("SPLUNK_MCP_URL", splunkMcpUrl);
    string resolvedDatadogUrl = envOrCfg("DATADOG_MCP_URL", datadogMcpUrl);
    string resolvedTopologyUrl = envOrCfg("BALLERINA_TOPOLOGY_MCP_URL", ballerinaTopologyMcpUrl);

    http:Client splunkMcp = check new (resolvedSplunkUrl, timeout = 30);
    http:Client datadogMcp = check new (resolvedDatadogUrl, timeout = 30);
    http:Client topologyMcp = check new (resolvedTopologyUrl, timeout = 30);

    // Initialize sessions.
    error? splunkInit = mcpInitialize(splunkMcp);
    error? ddInit = mcpInitialize(datadogMcp);
    error? topInit = mcpInitialize(topologyMcp);

    if splunkInit is error { log:printWarn("Splunk MCP init failed", 'error = splunkInit); }
    if ddInit is error { log:printWarn("Datadog MCP init failed", 'error = ddInit); }
    if topInit is error { log:printWarn("Topology MCP init failed", 'error = topInit); }

    // Collect tools from all servers (namespace with server prefix).
    AnthropicTool[] allTools = [];
    if splunkInit !is error {
        McpToolDef[]|error splunkTools = mcpListTools(splunkMcp);
        if splunkTools is McpToolDef[] {
            foreach McpToolDef t in splunkTools {
                allTools.push({name: string `splunk__${t.name}`, description: string `[splunk] ${t.description}`, input_schema: t.inputSchema});
            }
        }
    }
    if ddInit !is error {
        McpToolDef[]|error ddTools = mcpListTools(datadogMcp);
        if ddTools is McpToolDef[] {
            foreach McpToolDef t in ddTools {
                allTools.push({name: string `datadog__${t.name}`, description: string `[datadog] ${t.description}`, input_schema: t.inputSchema});
            }
        }
    }
    if topInit !is error {
        McpToolDef[]|error topTools = mcpListTools(topologyMcp);
        if topTools is McpToolDef[] {
            foreach McpToolDef t in topTools {
                allTools.push({name: string `topology__${t.name}`, description: string `[topology] ${t.description}`, input_schema: t.inputSchema});
            }
        }
    }

    // Build a dispatcher closure that routes tool calls to the right MCP client.
    function (string, json) returns string dispatcher = function(string toolName, json args) returns string {
        // Route by the REAL tool name (strip any "<prefix>__"). Robust to smaller models
        // emitting the wrong namespace prefix, e.g. topology__search_datadog_monitors.
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

    string userPrompt = buildInvestigationPrompt(alert.'service, alert.severity, alert.description, alert.id);
    string summary = check runConfiguredLlm(SYSTEM_PROMPT, userPrompt, allTools, dispatcher, 12);
    log:printInfo("investigation complete", 'service = alert.'service);
    return summary;
}

// Split a string on the first occurrence of a delimiter.
isolated function splitOnFirst(string s, string delimiter) returns string[]|error {
    int? idx = s.indexOf(delimiter);
    if idx is () { return error(string `Delimiter '${delimiter}' not found in '${s}'`); }
    return [s.substring(0, idx), s.substring(idx + delimiter.length())];
}
