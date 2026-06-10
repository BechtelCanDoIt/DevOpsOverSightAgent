import ballerina/http;
import ballerina/log;

listener http:Listener ddListener = new (8401);

service /health on ddListener {
    resource function get .() returns json {
        return {status: "UP", 'service: "datadog-mock-mcp"};
    }
}

service /mcp on ddListener {
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
                serverInfo: {name: "datadog-mock-mcp", 'version: "1.0.0"}
            }, id: reqId});
        } else if method == "notifications/initialized" || method == "ping" {
            resp.setJsonPayload({jsonrpc: "2.0", result: {}, id: reqId});
        } else if method == "tools/list" {
            resp.setJsonPayload({jsonrpc: "2.0", result: {tools: datadogToolsList()}, id: reqId});
        } else if method == "tools/call" {
            json params = check body.params;
            string toolName = (check params.name).toString();
            json arguments = check params.arguments;
            json|error result = callDatadogTool(toolName, arguments);
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
        log:printInfo("datadog-mock-mcp request", method = method);
        return resp;
    }
}

function datadogToolsList() returns json[] {
    return [
        {name: "get_datadog_metric", description: "Get a metric time series.",
         inputSchema: {'type: "object", properties: {
             metric_name: {'type: "string"},
             from_time: {'type: "integer"},
             to_time: {'type: "integer"}
         }, required: ["metric_name"]}},
        {name: "search_datadog_metrics", description: "Search metric names.",
         inputSchema: {'type: "object", properties: {
             query: {'type: "string"}
         }, required: ["query"]}},
        {name: "search_datadog_error_tracking_issues", description: "Search error tracking issues.",
         inputSchema: {'type: "object", properties: {
             query: {'type: "string"}
         }}},
        {name: "get_datadog_trace", description: "Get a full trace by ID.",
         inputSchema: {'type: "object", properties: {
             trace_id: {'type: "string"}
         }, required: ["trace_id"]}},
        {name: "apm_search_spans", description: "Search APM spans by service/operation.",
         inputSchema: {'type: "object", properties: {
             'service: {'type: "string"},
             operation: {'type: "string"}
         }}},
        {name: "search_datadog_logs", description: "Search Datadog log management.",
         inputSchema: {'type: "object", properties: {
             query: {'type: "string"}
         }}},
        {name: "search_datadog_monitors", description: "Search monitors by name or tag.",
         inputSchema: {'type: "object", properties: {
             query: {'type: "string"}
         }}},
        {name: "get_datadog_dashboard", description: "Get a dashboard by ID.",
         inputSchema: {'type: "object", properties: {
             dashboard_id: {'type: "string"}
         }, required: ["dashboard_id"]}}
    ];
}

function callDatadogTool(string name, json arguments) returns json|error {
    if name == "get_datadog_metric" {
        string metricName = (check arguments.metric_name).toString();
        MetricSeries? ms = lookupMetric(metricName);
        if ms is MetricSeries {
            return ms.toJson();
        }
        return {metric: metricName, series: [], note: "No data in mock — try payment.request.errors"}.toJson();
    }
    if name == "search_datadog_metrics" {
        string query = (check arguments.query).toString();
        json[] results = [];
        foreach var [k, v] in MOCK_METRICS.entries() {
            if k.toLowerAscii().includes(query.toLowerAscii()) {
                results.push({metric: v.metric, display_name: v.display_name, unit: v.unit});
            }
        }
        if results.length() > 0 {
            return results.toJson();
        }
        return [{metric: string `mock.${query}`, display_name: string `Mock ${query}`}].toJson();
    }
    if name == "search_datadog_error_tracking_issues" {
        json|error queryField = arguments.query;
        string query = queryField is json && !(queryField is ()) ? queryField.toString() : "";
        json[] issues = [
            {id: "ERR-001", title: "502 Bad Gateway in payment-service", 'service: "payment-service", occurrences: 47, status: "open"},
            {id: "ERR-002", title: "order creation failed: payment-service 502", 'service: "order-service", occurrences: 40, status: "open"}
        ];
        if query != "" {
            json[] filtered = [];
            foreach json issue in issues {
                string title = (check issue.title).toString();
                string svc = (check issue.'service).toString();
                if title.toLowerAscii().includes(query.toLowerAscii()) || svc.includes(query) {
                    filtered.push(issue);
                }
            }
            return filtered.toJson();
        }
        return issues.toJson();
    }
    if name == "get_datadog_trace" {
        string tid = (check arguments.trace_id).toString();
        if tid.startsWith("abc123") {
            return MOCK_TRACE.toJson();
        }
        return {trace_id: tid, spans: [], note: "No trace in mock — use demo trace_id starting with abc123"}.toJson();
    }
    if name == "apm_search_spans" {
        json|error svcField = arguments.'service;
        json|error opField = arguments.operation;
        string svcFilter = svcField is json && !(svcField is ()) ? svcField.toString() : "";
        string opFilter = opField is json && !(opField is ()) ? opField.toString() : "";
        ApmSpan[] spans = MOCK_TRACE.spans.clone();
        if svcFilter != "" {
            ApmSpan[] filtered = [];
            foreach ApmSpan s in spans {
                if s.'service.includes(svcFilter) {
                    filtered.push(s);
                }
            }
            spans = filtered;
        }
        if opFilter != "" {
            ApmSpan[] filtered = [];
            foreach ApmSpan s in spans {
                if s.operation.includes(opFilter) {
                    filtered.push(s);
                }
            }
            spans = filtered;
        }
        return spans.toJson();
    }
    if name == "search_datadog_logs" {
        json|error queryField = arguments.query;
        string query = queryField is json && !(queryField is ()) ? queryField.toString() : "";
        return filterLogs(query).toJson();
    }
    if name == "search_datadog_monitors" {
        json|error queryField = arguments.query;
        string query = queryField is json && !(queryField is ()) ? queryField.toString() : "";
        return filterMonitors(query).toJson();
    }
    if name == "get_datadog_dashboard" {
        string dashId = (check arguments.dashboard_id).toString();
        return {id: dashId, title: "DevOps POC — Service Overview",
            url: string `https://app.datadoghq.com/dashboard/${dashId}`,
            widgets: ["Service Error Rate", "Request Duration P99", "Active Monitors"]}.toJson();
    }
    return error(string `Unknown Datadog tool: ${name}`);
}
