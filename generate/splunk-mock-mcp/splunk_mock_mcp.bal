import ballerina/http;
import ballerina/log;

listener http:Listener splunkListener = new (8400);

service /health on splunkListener {
    resource function get .() returns json {
        return {status: "UP", 'service: "splunk-mock-mcp"};
    }
}

service /mcp on splunkListener {
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
                serverInfo: {name: "splunk-mock-mcp", 'version: "1.0.0"}
            }, id: reqId});
        } else if method == "notifications/initialized" || method == "ping" {
            resp.setJsonPayload({jsonrpc: "2.0", result: {}, id: reqId});
        } else if method == "tools/list" {
            json[] tools = [
                {name: "splunk_run_query",
                 description: "Run an SPL query against Splunk (mock). Returns matching log events.",
                 inputSchema: {'type: "object", properties: {
                     query: {'type: "string"},
                     earliest: {'type: "string", 'default: "-1h"},
                     latest: {'type: "string", 'default: "now"},
                     max_results: {'type: "integer", 'default: 100}
                 }, required: ["query"]}},
                {name: "splunk_get_indexes",
                 description: "List available Splunk indexes.",
                 inputSchema: {'type: "object", properties: {}}},
                {name: "splunk_get_knowledge_objects",
                 description: "Get knowledge objects like saved searches.",
                 inputSchema: {'type: "object", properties: {
                     object_type: {'type: "string", 'default: "saved_searches"}
                 }}},
                {name: "splunk_describe_query",
                 description: "Explain what an SPL query does.",
                 inputSchema: {'type: "object", properties: {
                     query: {'type: "string"}
                 }, required: ["query"]}}
            ];
            resp.setJsonPayload({jsonrpc: "2.0", result: {tools: tools}, id: reqId});
        } else if method == "tools/call" {
            json params = check body.params;
            string toolName = (check params.name).toString();
            json arguments = check params.arguments;
            json|error result = callSplunkTool(toolName, arguments);
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
        log:printInfo("splunk-mock-mcp request", method = method);
        return resp;
    }
}

function callSplunkTool(string name, json arguments) returns json|error {
    if name == "splunk_run_query" {
        string query = (check arguments.query).toString();
        int maxResults = 100;
        json mr = check arguments.max_results;
        if mr is int {
            maxResults = mr;
        }
        LogEvent[] events = filterEvents(query);
        if events.length() > maxResults {
            events = events.slice(0, maxResults);
        }
        return {query: query, result_count: events.length(), events: events.toJson()};
    }
    if name == "splunk_get_indexes" {
        return INDEXES.toJson();
    }
    if name == "splunk_get_knowledge_objects" {
        return SAVED_SEARCHES.toJson();
    }
    if name == "splunk_describe_query" {
        string query = (check arguments.query).toString();
        return {query: query, explanation: string `SPL query searches Splunk for: ${query}`, estimated_events: 42};
    }
    return error(string `Unknown Splunk tool: ${name}`);
}
