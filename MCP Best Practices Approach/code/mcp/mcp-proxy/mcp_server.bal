import ballerina/http;

listener http:Listener mcpListener = new (8290);

service /health on mcpListener {
    resource function get .() returns json {
        // Polling /health alone is enough to gradually connect every
        // configured backend (each attempt is cheap/back-off-bounded — see
        // ensureFederation in federation.bal), independent of any prior
        // tools/list call.
        ensureFederation();
        map<json> backends = {};
        foreach BackendDef def in backendDefs() {
            backends[def.label] = isBackendConnected(def.label);
        }
        return {status: "UP", 'service: "mcp-proxy", backends: backends};
    }
}

service /mcp on mcpListener {
    resource function post .(http:Request req) returns http:Response|error {
        // Optional bearer auth (R4.3) — empty PROXY_API_KEY (default) keeps
        // today's unauthenticated creds-free demo behavior unchanged.
        string expectedKey = envOr("PROXY_API_KEY", "");
        if expectedKey != "" {
            string|error authHeader = req.getHeader("Authorization");
            if authHeader is error || authHeader != string `Bearer ${expectedKey}` {
                http:Response unauthorized = new;
                unauthorized.statusCode = 401;
                unauthorized.setHeader("Content-Type", "application/json");
                unauthorized.setJsonPayload({
                    jsonrpc: "2.0",
                    'error: {code: -32001, message: "Unauthorized"},
                    id: ()
                });
                return unauthorized;
            }
        }

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

// Route a namespaced tool call to its origin. Strips the "<origin>__" prefix.
// Any prefix matching a known BackendDef label (federation.bal) routes to
// that backend; "topology__" (or any unrecognized/unprefixed name) falls
// through to the local dispatchTool — preserving the original behavior of
// treating unknown prefixes as local calls.
function routeToolCall(string toolName, json arguments) returns string|error {
    string origin = "topology";
    string realName = toolName;
    int? sep = toolName.indexOf("__");
    if sep is int {
        origin = toolName.substring(0, sep);
        realName = toolName.substring(sep + 2);
    }
    if origin == "topology" || !isKnownBackendLabel(origin) {
        return dispatchTool(realName, arguments);
    }
    return callBackend(getBackend(origin), origin, realName, arguments, registryHas(toolName));
}

// Forward a de-prefixed tool call to a downstream MCP backend. `registered`
// distinguishes "backend simply isn't connected yet" (retry-friendly) from
// "backend is up but this specific tool was never registered" — the latter
// covers both a genuinely unknown tool name AND a write-guardrail-filtered
// one (R4.2); the caller (the agent) cannot tell those apart, by design.
function callBackend(http:Client? backend, string label, string realName, json args, boolean registered) returns string|error {
    if backend is () {
        return error(string `${label} MCP backend is unavailable (not connected). Retry shortly.`);
    }
    if !registered {
        return error(string `${label}__${realName} is not available (not discovered, or write-restricted — write actions run only via topology__run_runbook).`);
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
        ServiceHealthProbe p = probeServiceHealth(svc);
        if p.status == "UNKNOWN" { return {'service: name, status: "UNKNOWN"}.toJsonString(); }
        if p.status == "DOWN" { return {'service: name, status: "DOWN", 'error: p.errorMsg}.toJsonString(); }
        return {'service: name, status: p.status, httpStatus: p.httpStatus}.toJsonString();
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
    if toolName == "suggest_runbooks" {
        string svc = (check arguments.'service).toString();
        string diagnosis = (check arguments.diagnosis).toString();
        RunbookSuggestion[] suggestions = suggestRunbooks(svc, diagnosis);
        return {'service: svc, diagnosis: diagnosis, suggestions: suggestions.toJson()}.toJsonString();
    }
    if toolName == "health_report" {
        map<json> argsMap = <map<json>>arguments;
        json? productJ = argsMap["product"];
        string? product = productJ is string ? productJ : ();
        return healthReport(product).toJsonString();
    }
    if toolName == "top_issues" {
        map<json> argsMap = <map<json>>arguments;
        int count = 5;
        json|error countJ = arguments.count;
        if countJ is int { count = countJ; }
        json? productJ = argsMap["product"];
        string? product = productJ is string ? productJ : ();
        Issue[] issues = topIssues(count, product);
        return {issues: issues.toJson()}.toJsonString();
    }
    if toolName == "list_deployments" {
        return listDeployments().toJson().toJsonString();
    }
    return error(string `Unknown tool: ${toolName}`);
}
