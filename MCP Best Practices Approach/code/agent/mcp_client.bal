// Minimal MCP client — connects to an MCP server over HTTP (Streamable HTTP transport).
// Sends JSON-RPC 2.0 POST requests to /mcp and returns the result.

import ballerina/http;
import ballerina/lang.value;

type McpToolDef record {|
    string name;
    string description;
    json inputSchema;
|};

type McpToolResult record {|
    string text;
    boolean isError;
|};

// The agent only ever talks to the MCP Proxy directly (which is lenient, like
// our own mock servers), but this client shape is kept identical to the
// proxy's own copy — including the Accept header and SSE-aware body parsing
// — so it behaves correctly if ever pointed at a real MCP server directly.
// See the proxy's mcp_client.bal for why: a spec-compliant Streamable HTTP
// server requires this Accept header (else HTTP 400) and may reply with
// SSE-framed text/event-stream instead of bare JSON even for a single
// request/response (discovered wiring the Kubernetes MCP backend, Phase 6.4).
final map<string> & readonly MCP_HEADERS = {
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream"
};

// Adds an Authorization: Bearer header when PROXY_API_KEY is configured — the
// proxy's optional bearer auth (see mcp-proxy's Refactor R4.3). Empty (the
// default) means no header, matching the proxy's unauthenticated default.
isolated function mcpHeaders() returns map<string> {
    map<string> headers = MCP_HEADERS.clone();
    string key = envOr("PROXY_API_KEY", "");
    if key != "" {
        headers["Authorization"] = string `Bearer ${key}`;
    }
    return headers;
}

isolated function extractJsonBody(http:Response resp) returns json|error {
    string|error ctypeResult = resp.getHeader("Content-Type");
    string ctype = ctypeResult is string ? ctypeResult : "";
    if !ctype.includes("text/event-stream") {
        return resp.getJsonPayload();
    }
    string bodyText = check resp.getTextPayload();
    foreach string line in splitLines(bodyText) {
        string trimmed = line.trim();
        if trimmed.startsWith("data:") {
            return value:fromJsonString(trimmed.substring(5).trim());
        }
    }
    return error("SSE response contained no 'data:' line");
}

isolated function splitLines(string s) returns string[] {
    string[] result = [];
    string remaining = s;
    while remaining.length() > 0 {
        int? nlIdx = remaining.indexOf("\n");
        string line;
        if nlIdx is int {
            line = remaining.substring(0, nlIdx);
            remaining = remaining.substring(nlIdx + 1);
        } else {
            line = remaining;
            remaining = "";
        }
        result.push(line);
    }
    return result;
}

// Initialize an MCP session (sends the initialize handshake).
function mcpInitialize(http:Client mcpClient) returns error? {
    json initReq = {jsonrpc: "2.0", method: "initialize", params: {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: {name: "ballerina-devops-oversight-agent", 'version: "1.0.0"}
    }, id: 1};
    http:Response resp = check mcpClient->post("/mcp", initReq, mcpHeaders());
    if resp.statusCode != 200 {
        return error(string `MCP initialize failed: HTTP ${resp.statusCode}`);
    }
    // Send initialized notification (no response expected).
    json notif = {jsonrpc: "2.0", method: "notifications/initialized", params: {}};
    http:Response _ = check mcpClient->post("/mcp", notif, mcpHeaders());
}

// List tools available from an MCP server.
function mcpListTools(http:Client mcpClient) returns McpToolDef[]|error {
    json req = {jsonrpc: "2.0", method: "tools/list", params: {}, id: 2};
    http:Response resp = check mcpClient->post("/mcp", req, mcpHeaders());
    json body = check extractJsonBody(resp);
    json[] rawTools = <json[]>(check body.result.tools);
    McpToolDef[] tools = [];
    foreach json t in rawTools {
        tools.push({
            name: (check t.name).toString(),
            description: (check t.description).toString(),
            inputSchema: check t.inputSchema
        });
    }
    return tools;
}

// Call a tool on an MCP server.
function mcpCallTool(http:Client mcpClient, string toolName, json arguments, int callId) returns McpToolResult|error {
    json req = {jsonrpc: "2.0", method: "tools/call", params: {name: toolName, arguments: arguments}, id: callId};
    http:Response resp = check mcpClient->post("/mcp", req, mcpHeaders());
    json body = check extractJsonBody(resp);
    // Check for JSON-RPC error.
    json|error rpcErrField = body.'error;
    if rpcErrField is json && rpcErrField !is () {
        string msg = (check rpcErrField.message).toString();
        return {text: string `Tool error: ${msg}`, isError: true};
    }
    json result = check body.result;
    json[] content = <json[]>(check result.content);
    if content.length() == 0 {
        return {text: "(empty result)", isError: false};
    }
    string text = (check content[0].text).toString();
    json|error isErrField = result.isError;
    boolean isErr = isErrField is boolean && isErrField == true;
    return {text: text, isError: isErr};
}
