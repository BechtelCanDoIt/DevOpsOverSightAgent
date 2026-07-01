// Federation + tool registry for the MCP Proxy.
//
// The proxy is the single MCP entry point for the agent. It:
//   1. Connects to the downstream Splunk / Datadog MCP servers (lazily, on
//      first use — robust to container start order).
//   2. Namespaces every federated tool (splunk__, datadog__, topology__) and
//      registers it in a searchable registry.
//   3. Answers discover_tools(query) by scoring the registry and returning the
//      matching tool manifests — this is the lazy-loading / semantic-router
//      entry point (see mcp best practices Patterns 2, 3, 6).
//   4. Routes tools/call to the right backend by stripping the namespace prefix
//      (see mcp_server.bal routeToolCall).

import ballerina/http;
import ballerina/log;

// ── Backend MCP URLs — set in Config.toml; env vars override at runtime ───────
configurable string splunkMcpUrl   = "http://splunk-mock-mcp:8400";
configurable string datadogMcpUrl  = "http://datadog-mock-mcp:8401";

// A registry entry is a namespaced tool manifest the agent can be handed.
type RegistryEntry record {|
    string name;
    string description;
    json inputSchema;
|};

// ── Registry state (isolated + lock, matching runbooks.bal) ──────────────────

isolated map<RegistryEntry> toolRegistry = {};
isolated http:Client? splunkBackend = ();
isolated http:Client? datadogBackend = ();
isolated boolean federationReady = false;

isolated function registerTool(RegistryEntry e) {
    lock {
        toolRegistry[e.name] = e.clone();
    }
}

isolated function snapshotRegistry() returns map<RegistryEntry> {
    lock {
        return toolRegistry.clone();
    }
}

isolated function getSplunkBackend() returns http:Client? {
    lock {
        return splunkBackend;
    }
}

isolated function getDatadogBackend() returns http:Client? {
    lock {
        return datadogBackend;
    }
}

// ── Topology tool definitions (single source of truth) ───────────────────────
// Used both to build tools/list and to seed the registry. Names carry the
// topology__ prefix; the prefix is stripped in routeToolCall before dispatch.

isolated function topologyToolDefs() returns RegistryEntry[] {
    return [
        {name: "topology__lookup_service",
         description: "[topology] Look up a service by name — returns owner, dependencies, runbooks, SLA, health endpoint.",
         inputSchema: {'type: "object", properties: {name: {'type: "string"}}, required: ["name"]}},
        {name: "topology__get_dependencies",
         description: "[topology] Get dependency graph. direction=downstream/upstream/both.",
         inputSchema: {'type: "object",
             properties: {name: {'type: "string"}, direction: {'type: "string", 'enum: ["upstream", "downstream", "both"]}},
             required: ["name", "direction"]}},
        {name: "topology__list_services",
         description: "[topology] List all 7 mesh services.",
         inputSchema: {'type: "object", properties: {}}},
        {name: "topology__get_service_health",
         description: "[topology] Probe a service health endpoint live.",
         inputSchema: {'type: "object", properties: {name: {'type: "string"}}, required: ["name"]}},
        {name: "topology__correlate_trace",
         description: "[correlation] Given a trace_id, return Datadog URL + Splunk SPL + involved services.",
         inputSchema: {'type: "object", properties: {trace_id: {'type: "string"}}, required: ["trace_id"]}},
        {name: "topology__find_recent_deploys",
         description: "[correlation] Find recent deployments for a service.",
         inputSchema: {'type: "object",
             properties: {'service: {'type: "string"}, lookback_minutes: {'type: "integer"}},
             required: ["service"]}},
        {name: "topology__find_related_incidents",
         description: "[correlation] Search past incidents for a service.",
         inputSchema: {'type: "object",
             properties: {'service: {'type: "string"}, lookback_days: {'type: "integer"}},
             required: ["service"]}},
        {name: "topology__list_runbooks",
         description: "[runbook] List all available runbooks.",
         inputSchema: {'type: "object", properties: {}}},
        {name: "topology__run_runbook",
         description: "[runbook] Execute a runbook. Always propose to operator before calling.",
         inputSchema: {'type: "object",
             properties: {id: {'type: "string"}, params: {'type: "object"}},
             required: ["id"]}},
        {name: "topology__get_audit_log",
         description: "[runbook] Return the runbook execution audit log for this session.",
         inputSchema: {'type: "object", properties: {}}},
        {name: "topology__get_deploy_freeze_status",
         description: "[runbook] Check whether a deploy freeze is active and why.",
         inputSchema: {'type: "object", properties: {}}}
    ];
}

// The discover_tools manifest — the one lazy-loading entry point advertised in
// tools/list alongside the topology tools.
isolated function discoverToolDef() returns json => {
    name: "discover_tools",
    description: "Search for Splunk/Datadog tools by capability and get their schemas so you can call them. " +
        "Call this before using any splunk__ or datadog__ tool. " +
        "Examples: \"Splunk log query\", \"Datadog metric trace APM\", \"Datadog monitor error tracking\".",
    inputSchema: {
        'type: "object",
        properties: {
            query: {'type: "string",
                description: "Natural language description of the capability needed (e.g. \"Splunk logs query\", \"Datadog metric time series\", \"Datadog trace APM spans\")."}
        },
        required: ["query"]
    }
};

// ── Lazy federation ───────────────────────────────────────────────────────────
// Registers topology tools (no network) and connects to the Splunk/Datadog
// backends, registering their namespaced tools. Non-fatal: a backend that is
// down just logs a warning and is retried on the next call until both connect.

function ensureFederation() {
    boolean ready;
    lock {
        ready = federationReady;
    }
    if ready {
        return;
    }

    // Topology tools need no network — always register them.
    foreach RegistryEntry e in topologyToolDefs() {
        registerTool(e);
    }

    string splunkUrl  = envOrCfg("SPLUNK_MCP_URL",   splunkMcpUrl);
    string datadogUrl = envOrCfg("DATADOG_MCP_URL",  datadogMcpUrl);
    http:Client? sc = connectBackend("splunk", splunkUrl);
    http:Client? dc = connectBackend("datadog", datadogUrl);

    boolean bothUp = sc is http:Client && dc is http:Client;
    // One restricted variable per lock (Ballerina isolation rule).
    lock {
        splunkBackend = sc;
    }
    lock {
        datadogBackend = dc;
    }
    // Only latch ready when both backends are connected; otherwise a later
    // call retries (topology tools are already registered regardless).
    if bothUp {
        lock {
            federationReady = true;
        }
    }
}

// Connect to one backend, list its tools, and register them namespaced.
// Returns () (with a warning) if the backend is unreachable.
function connectBackend(string label, string url) returns http:Client? {
    http:Client|error c = new (url, timeout = 30);
    if c is error {
        log:printWarn("MCP backend client construction failed", label = label, url = url, 'error = c);
        return ();
    }
    error? initErr = mcpInitialize(c);
    if initErr is error {
        log:printWarn("MCP backend initialize failed — will retry on next call", label = label, url = url, 'error = initErr);
        return ();
    }
    McpToolDef[]|error tools = mcpListTools(c);
    if tools is error {
        log:printWarn("MCP backend tools/list failed", label = label, url = url, 'error = tools);
        return ();
    }
    string prefix = label + "__";
    string tag = "[" + label + "]";
    foreach McpToolDef t in tools {
        registerTool({name: prefix + t.name, description: tag + " " + t.description, inputSchema: t.inputSchema});
    }
    log:printInfo("federated MCP backend", label = label, url = url, toolCount = tools.length());
    return c;
}

// ── discover_tools handler ──────────────────────────────────────────────────
// Returns guidance text for empty/no-match queries, or a JSON manifest bundle
// {"tools":[{name,description,input_schema},...]} the agent absorbs into its
// active tool set.

function handleDiscover(json arguments) returns string {
    json|error queryField = arguments.query;
    string query = queryField is json ? queryField.toString() : "";
    if query.trim() == "" {
        return "Provide a non-empty query, e.g. \"Splunk logs\", \"Datadog metric trace\", \"topology runbook\".";
    }
    RegistryEntry[] found = searchRegistry(snapshotRegistry(), query, 5);
    if found.length() == 0 {
        return string `No tools matched "${query}". Try: "Splunk logs query", "Datadog metric trace APM monitor", or "topology service dependency runbook correlate".`;
    }
    json[] manifests = [];
    foreach RegistryEntry e in found {
        manifests.push({name: e.name, description: e.description, input_schema: e.inputSchema});
    }
    return {tools: manifests}.toJsonString();
}

// ── Keyword scorer + registry search (moved here from the agent) ─────────────

// Score how well a tool matches a query. Words > 2 chars: exact match = +2,
// 4-char prefix match (handles plurals/stems) = +1 for words length >= 5.
isolated function scoreToolMatch(string name, string description, string query) returns int {
    string haystack = string `${name} ${description}`.toLowerAscii();
    int score = 0;
    string remaining = query.toLowerAscii();
    while remaining.length() > 0 {
        int? spaceIdx = remaining.indexOf(" ");
        string word;
        if spaceIdx is int {
            word = remaining.substring(0, spaceIdx);
            remaining = remaining.substring(spaceIdx + 1);
        } else {
            word = remaining;
            remaining = "";
        }
        if word.length() <= 2 {
            continue;
        }
        if haystack.includes(word) {
            score += 2;
        } else if word.length() >= 5 && haystack.includes(word.substring(0, 4)) {
            score += 1;
        }
    }
    return score;
}

// Return up to maxResults tools from registry ranked by query relevance.
// Returns empty array when nothing scores > 0.
isolated function searchRegistry(map<RegistryEntry> registry, string query, int maxResults) returns RegistryEntry[] {
    [string, int][] scored = [];
    foreach string k in registry.keys() {
        RegistryEntry t = registry.get(k);
        int s = scoreToolMatch(t.name, t.description, query);
        if s > 0 {
            scored.push([k, s]);
        }
    }
    // Selection sort descending by score (N is small, cost is negligible).
    int sz = scored.length();
    int ii = 0;
    while ii < sz - 1 {
        int bestIdx = ii;
        int jj = ii + 1;
        while jj < sz {
            if scored[jj][1] > scored[bestIdx][1] {
                bestIdx = jj;
            }
            jj += 1;
        }
        if bestIdx != ii {
            [string, int] tmp = scored[ii];
            scored[ii] = scored[bestIdx];
            scored[bestIdx] = tmp;
        }
        ii += 1;
    }
    RegistryEntry[] result = [];
    int lim = scored.length() < maxResults ? scored.length() : maxResults;
    int idx = 0;
    while idx < lim {
        result.push(registry.get(scored[idx][0]));
        idx += 1;
    }
    return result;
}
