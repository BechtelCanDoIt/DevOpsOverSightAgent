// mi-mcp — wraps WSO2 Micro Integrator's built-in Management API as an MCP
// server. MODE=mock (default, creds-free) serves deterministic fixtures from
// mock_data.bal; MODE=live calls a real MI instance via live_client.bal.
// Federated by the MCP Proxy under the "mi" backend label (see
// federation.bal backendDefs() in mcp-proxy — Refactor R4).

import ballerina/http;
import ballerina/log;

listener http:Listener miListener = new (8403);

isolated function currentMode() returns string => envOr("MODE", "mock");

service /health on miListener {
    resource function get .() returns json {
        return {status: "UP", 'service: "mi-mcp", mode: currentMode()};
    }
}

service /mcp on miListener {
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
                serverInfo: {name: "mi-mcp", 'version: "1.0.0"}
            }, id: reqId});
        } else if method == "notifications/initialized" || method == "ping" {
            resp.setJsonPayload({jsonrpc: "2.0", result: {}, id: reqId});
        } else if method == "tools/list" {
            resp.setJsonPayload({jsonrpc: "2.0", result: {tools: miToolDefs()}, id: reqId});
        } else if method == "tools/call" {
            json params = check body.params;
            string toolName = (check params.name).toString();
            json arguments = check params.arguments;
            json|error result = callMiTool(toolName, arguments);
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
        log:printInfo("mi-mcp request", method = method, mode = currentMode());
        return resp;
    }
}

function miToolDefs() returns json[] => [
    {name: "mi_health",
     description: "Check WSO2 Micro Integrator health/reachability.",
     inputSchema: {'type: "object", properties: {}}},
    {name: "mi_list_proxy_services",
     description: "List all proxy services and whether each is running.",
     inputSchema: {'type: "object", properties: {}}},
    {name: "mi_list_apis",
     description: "List all integration APIs.",
     inputSchema: {'type: "object", properties: {}}},
    {name: "mi_list_endpoints",
     description: "List all configured endpoints and their active status.",
     inputSchema: {'type: "object", properties: {}}},
    {name: "mi_get_message_processors",
     description: "List message processors, their state (ACTIVE/INACTIVE), and queued message count — use to spot stuck queues.",
     inputSchema: {'type: "object", properties: {}}},
    {name: "mi_get_logs",
     description: "Fetch recent carbon/integration log lines.",
     inputSchema: {'type: "object", properties: {}}}
];

function callMiTool(string name, json arguments) returns json|error {
    if currentMode() == "live" {
        return callMiLive(name, arguments);
    }
    return callMiMock(name, arguments);
}
