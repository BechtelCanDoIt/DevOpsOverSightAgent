// apim-mcp — wraps WSO2 API Manager's built-in REST APIs as an MCP server.
// MODE=mock (default, creds-free) serves deterministic fixtures from
// mock_data.bal; MODE=live calls a real APIM instance via live_client.bal.
// Federated by the MCP Proxy under the "apim" backend label (see
// federation.bal backendDefs() in mcp-proxy — Refactor R4).

import ballerina/http;
import ballerina/log;

listener http:Listener apimListener = new (8402);

isolated function currentMode() returns string => envOr("MODE", "mock");

service /health on apimListener {
    resource function get .() returns json {
        return {status: "UP", 'service: "apim-mcp", mode: currentMode()};
    }
}

service /mcp on apimListener {
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
                serverInfo: {name: "apim-mcp", 'version: "1.0.0"}
            }, id: reqId});
        } else if method == "notifications/initialized" || method == "ping" {
            resp.setJsonPayload({jsonrpc: "2.0", result: {}, id: reqId});
        } else if method == "tools/list" {
            resp.setJsonPayload({jsonrpc: "2.0", result: {tools: apimToolDefs()}, id: reqId});
        } else if method == "tools/call" {
            json params = check body.params;
            string toolName = (check params.name).toString();
            json arguments = check params.arguments;
            json|error result = callApimTool(toolName, arguments);
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
        log:printInfo("apim-mcp request", method = method, mode = currentMode());
        return resp;
    }
}

function apimToolDefs() returns json[] => [
    {name: "apim_health",
     description: "Check WSO2 API Manager health/reachability.",
     inputSchema: {'type: "object", properties: {}}},
    {name: "apim_list_apis",
     description: "List all APIs known to the Publisher.",
     inputSchema: {'type: "object", properties: {}}},
    {name: "apim_get_api",
     description: "Get a single API by id or name.",
     inputSchema: {'type: "object", properties: {
         id: {'type: "string"}, name: {'type: "string"}
     }}},
    {name: "apim_list_applications",
     description: "List Developer Portal applications.",
     inputSchema: {'type: "object", properties: {}}},
    {name: "apim_list_subscriptions",
     description: "List API subscriptions (application ⇄ API bindings).",
     inputSchema: {'type: "object", properties: {}}},
    {name: "apim_gateway_status",
     description: "Get gateway environment status.",
     inputSchema: {'type: "object", properties: {}}}
];

function callApimTool(string name, json arguments) returns json|error {
    if currentMode() == "live" {
        return callApimLive(name, arguments);
    }
    return callApimMock(name, arguments);
}
