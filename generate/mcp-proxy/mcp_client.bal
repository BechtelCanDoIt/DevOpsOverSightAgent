// Minimal MCP client — the proxy uses this to federate the downstream
// Splunk / Datadog MCP servers over HTTP (Streamable HTTP transport).
// Sends JSON-RPC 2.0 POST requests to /mcp and returns the result.
//
// This is a deliberate copy of the agent's mcp_client.bal: Ballerina packages
// do not share code without a shared module, and the duplication is small.
// The proxy is now BOTH an MCP server (to the agent) and an MCP client
// (to the backends).

import ballerina/http;

type McpToolDef record {|
    string name;
    string description;
    json inputSchema;
|};

type McpToolResult record {|
    string text;
    boolean isError;
|};

// Initialize an MCP session (sends the initialize handshake).
function mcpInitialize(http:Client mcpClient) returns error? {
    json initReq = {jsonrpc: "2.0", method: "initialize", params: {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: {name: "ballerina-devops-mcp-proxy", 'version: "1.0.0"}
    }, id: 1};
    http:Response resp = check mcpClient->post("/mcp", initReq, {"Content-Type": "application/json"});
    if resp.statusCode != 200 {
        return error(string `MCP initialize failed: HTTP ${resp.statusCode}`);
    }
    // Send initialized notification (no response expected).
    json notif = {jsonrpc: "2.0", method: "notifications/initialized", params: {}};
    http:Response _ = check mcpClient->post("/mcp", notif, {"Content-Type": "application/json"});
}

// List tools available from an MCP server.
function mcpListTools(http:Client mcpClient) returns McpToolDef[]|error {
    json req = {jsonrpc: "2.0", method: "tools/list", params: {}, id: 2};
    http:Response resp = check mcpClient->post("/mcp", req, {"Content-Type": "application/json"});
    json body = check resp.getJsonPayload();
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
    http:Response resp = check mcpClient->post("/mcp", req, {"Content-Type": "application/json"});
    json body = check resp.getJsonPayload();
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
