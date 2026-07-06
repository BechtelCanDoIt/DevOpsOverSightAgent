import ballerina/http;

listener http:Listener mcpListener = new (8290);

service /health on mcpListener {
    resource function get .() returns json => {status: "UP", 'service: "mcp-proxy"};
}

service /mcp on mcpListener {
    resource function post .(http:Request req) returns http:Response|error {
        json body = check req.getJsonPayload();
        string method = (check body.method).toString();
        json? reqId = check body.id;

        http:Response resp = new;
        resp.setHeader("Content-Type", "application/json");

        if method == "initialize" {
            resp.setJsonPayload({
                jsonrpc: "2.0",
                result: {
                    protocolVersion: "2024-11-05",
                    capabilities: {tools: {}},
                    serverInfo: {name: "ballerina-devops-mcp", 'version: "1.0.0"}
                },
                id: reqId
            });
        } else if method == "notifications/initialized" || method == "ping" {
            resp.setJsonPayload({jsonrpc: "2.0", result: {}, id: reqId});
        } else if method == "tools/list" {
            ensureFederation();
            resp.setJsonPayload(check buildToolsListResponse(reqId));
        } else if method == "tools/call" {
            ensureFederation();
            json params = check body.params;
            string toolName = (check params.name).toString();
            json|error argResult = params.arguments;
            json arguments = argResult is json ? argResult : {};
            resp.setJsonPayload(check buildToolCallResponse(reqId, toolName, arguments));
        } else {
            resp.setJsonPayload({
                jsonrpc: "2.0",
                'error: {code: -32601, message: string `Method not found: ${method}`},
                id: reqId
            });
        }
        return resp;
    }
}

// tools/list advertises the pre-seed set the agent loads on turn 1:
// discover_tools + the topology tools. The federated splunk__/datadog__ tools
// stay OUT of tools/list — they are revealed lazily via discover_tools — which
// keeps the agent's turn-1 context small (mcp best practices Patterns 1, 2).
function buildToolsListResponse(json? id) returns json|error {
    json[] tools = [discoverToolDef()];
    foreach RegistryEntry e in topologyToolDefs() {
        tools.push({name: e.name, description: e.description, inputSchema: e.inputSchema});
    }
    return {jsonrpc: "2.0", result: {tools: tools}, id: id};
}

function buildToolCallResponse(json? id, string toolName, json arguments) returns json|error {
    if toolName == "discover_tools" {
        string content = handleDiscover(arguments);
        return {jsonrpc: "2.0", result: {content: [{'type: "text", text: content}], isError: false}, id: id};
    }
    string|error content = routeToolCall(toolName, arguments);
    if content is error {
        return {jsonrpc: "2.0", 'error: {code: -32603, message: content.message()}, id: id};
    }
    return {jsonrpc: "2.0", result: {content: [{'type: "text", text: content}], isError: false}, id: id};
}

// Route a namespaced tool call to its origin. Strips the "<origin>__" prefix:
//   splunk__*   → Splunk MCP backend
//   datadog__*  → Datadog MCP backend
//   topology__* (or unprefixed) → local dispatchTool
function routeToolCall(string toolName, json arguments) returns string|error {
    string origin = "topology";
    string realName = toolName;
    int? sep = toolName.indexOf("__");
    if sep is int {
        origin = toolName.substring(0, sep);
        realName = toolName.substring(sep + 2);
    }
    if origin == "splunk" {
        return callBackend(getSplunkBackend(), "splunk", realName, arguments);
    }
    if origin == "datadog" {
        return callBackend(getDatadogBackend(), "datadog", realName, arguments);
    }
    return dispatchTool(realName, arguments);
}

// Forward a de-prefixed tool call to a downstream MCP backend.
function callBackend(http:Client? backend, string label, string realName, json args) returns string|error {
    if backend is () {
        return error(string `${label} MCP backend is unavailable (not connected). Retry shortly.`);
    }
    McpToolResult result = check mcpCallTool(backend, realName, args, 99);
    return result.text;
}

function dispatchTool(string toolName, json arguments) returns string|error {
    if toolName == "lookup_service" {
        string name = (check arguments.name).toString();
        ServiceInfo? svc = catalogLookup(name);
        return svc is () ? string `Not found: ${name}. Known: ${", ".join(...listAllServices())}` : svc.toJsonString();
    }
    if toolName == "get_dependencies" {
        string name = (check arguments.name).toString();
        string dir = (check arguments.direction).toString();
        return {'service: name, direction: dir, dependencies: getDependencies(name, dir)}.toJsonString();
    }
    if toolName == "list_services" {
        json[] svcs = [];
        foreach var [_, s] in SERVICE_CATALOG.entries() {
            svcs.push({name: s.name, owner: s.owner, sla: s.sla});
        }
        return svcs.toJsonString();
    }
    if toolName == "get_service_health" {
        string name = (check arguments.name).toString();
        ServiceInfo? svc = catalogLookup(name);
        if svc is () { return string `Unknown service: ${name}`; }
        http:Client|error hc = new (svc.healthEndpoint, timeout = 3);
        if hc is error { return {'service: name, status: "UNKNOWN"}.toJsonString(); }
        http:Response|error r = hc->get("/");
        return r is http:Response ?
            {'service: name, status: r.statusCode == 200 ? "UP" : "DEGRADED", httpStatus: r.statusCode}.toJsonString() :
            {'service: name, status: "DOWN", 'error: r.message()}.toJsonString();
    }
    if toolName == "correlate_trace" {
        string tid = (check arguments.trace_id).toString();
        string ddSite = envOr("DD_SITE", "datadoghq.com");
        string splunkUrl = envOr("SPLUNK_URL", "https://your-splunk.splunkcloud.com");
        return {
            trace_id: tid,
            datadog_url: buildDatadogTraceUrl(tid, ddSite),
            splunk_search_url: buildSplunkSearchUrl(tid, splunkUrl),
            splunk_spl: buildSplunkSpl(tid),
            involved_services: inferInvolvedServices(tid),
            note: "Use Datadog MCP get_datadog_trace and Splunk MCP splunk_run_query to fetch data."
        }.toJsonString();
    }
    if toolName == "find_recent_deploys" {
        map<json> argsMap = <map<json>>arguments;
        string svc = (argsMap["service"] ?: "").toString();
        int lb = 60;
        json|error lbj = arguments.lookback_minutes;
        if lbj is int { lb = lbj; }
        return {'service: svc, lookback_minutes: lb, deploys: findRecentDeploys(svc, lb)}.toJsonString();
    }
    if toolName == "find_related_incidents" {
        map<json> argsMap = <map<json>>arguments;
        string svc = (argsMap["service"] ?: "").toString();
        int days = 30;
        json|error dj = arguments.lookback_days;
        if dj is int { days = dj; }
        return {'service: svc, lookback_days: days, incidents: findRelatedIncidents(svc, days)}.toJsonString();
    }
    if toolName == "list_runbooks" {
        return listRunbooks().toJsonString();
    }
    if toolName == "run_runbook" {
        string rbId = (check arguments.id).toString();
        json|error pjResult = arguments.params;
        json pj = pjResult is json ? pjResult : {};
        map<string> params = {};
        if pj is map<json> { foreach var [k, v] in pj.entries() { params[k] = v.toString(); } }
        string[]|error steps = executeRunbook(rbId, params);
        if steps is error { return error(string `Runbook error: ${steps.message()}`); }
        return {runbook: rbId, steps: steps}.toJsonString();
    }
    if toolName == "get_audit_log" {
        return {entries: getAuditLog()}.toJsonString();
    }
    if toolName == "get_deploy_freeze_status" {
        return {frozen: isDeployFrozen(), reason: getDeployFreezeReason()}.toJsonString();
    }
    return error(string `Unknown tool: ${toolName}`);
}
