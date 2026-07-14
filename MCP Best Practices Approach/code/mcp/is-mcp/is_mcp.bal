// is-mcp — wraps WSO2 Identity Server's built-in health-check/server-mgmt/
// SCIM2 REST APIs as an MCP server. MODE=mock (default, creds-free) serves
// deterministic fixtures from mock_data.bal; MODE=live calls a real IS
// instance via live_client.bal. Federated by the MCP Proxy under the "is"
// backend label (see federation.bal backendDefs() in mcp-proxy — Refactor R4).

import ballerina/http;
import ballerina/log;

listener http:Listener isListener = new (8404);

isolated function currentMode() returns string => envOr("MODE", "mock");

service /health on isListener {
    resource function get .() returns json {
        return {status: "UP", 'service: "is-mcp", mode: currentMode()};
    }
}

service /mcp on isListener {
    resource function post .(http:Request req) returns http:Response|error {
        json body = check req.getJsonPayload();
        string method = (check body.method).toString();
        json reqId = check body.id;

        http:Response resp = new;
        resp.setHeader("Content-Type", "application/json");

        if method == "initialize" {
            resp.setJsonPayload({jsonrpc: "2.0", result: {
                protocolVersion: "2024-11-05",
                capabilities: {tools: {}},
                serverInfo: {name: "is-mcp", 'version: "1.0.0"}
            }, id: reqId});
        } else if method == "notifications/initialized" || method == "ping" {
            resp.setJsonPayload({jsonrpc: "2.0", result: {}, id: reqId});
        } else if method == "tools/list" {
            resp.setJsonPayload({jsonrpc: "2.0", result: {tools: isToolDefs()}, id: reqId});
        } else if method == "tools/call" {
            json params = check body.params;
            string toolName = (check params.name).toString();
            json arguments = check params.arguments;
            json|error result = callIsTool(toolName, arguments);
            if result is error {
                resp.setJsonPayload({jsonrpc: "2.0", 'error: {code: -32603, message: result.message()}, id: reqId});
            } else {
                resp.setJsonPayload({jsonrpc: "2.0", result: {
                    content: [{'type: "text", text: result.toJsonString()}],
                    isError: false
                }, id: reqId});
            }
        } else {
            resp.setJsonPayload({jsonrpc: "2.0", 'error: {
                code: -32601,
                message: string `Method not found: ${method}`
            }, id: reqId});
        }
        log:printInfo("is-mcp request", method = method, mode = currentMode());
        return resp;
    }
}

function isToolDefs() returns json[] => [
    {name: "is_health",
     description: "Check WSO2 Identity Server health/reachability.",
     inputSchema: {'type: "object", properties: {}}},
    {name: "is_server_info",
     description: "Get Identity Server version/build info.",
     inputSchema: {'type: "object", properties: {}}},
    {name: "is_list_applications",
     description: "List registered applications (service providers).",
     inputSchema: {'type: "object", properties: {}}},
    {name: "is_user_store_status",
     description: "List configured user stores and their connection status.",
     inputSchema: {'type: "object", properties: {}}},
    {name: "is_count_users",
     description: "Count total users across all user stores (via SCIM2).",
     inputSchema: {'type: "object", properties: {}}}
];

function callIsTool(string name, json arguments) returns json|error {
    if currentMode() == "live" {
        return callIsLive(name, arguments);
    }
    return callIsMock(name, arguments);
}
