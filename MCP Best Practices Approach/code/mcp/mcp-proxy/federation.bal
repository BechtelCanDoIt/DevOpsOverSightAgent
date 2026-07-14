// Federation + tool registry for the MCP Proxy.
//
// The proxy is the single MCP entry point for the agent. It:
//   1. Connects to downstream MCP backends (lazily, on first use — robust to
//      container start order; a down OPTIONAL backend never blocks anything).
//   2. Namespaces every federated tool (splunk__, datadog__, apim__, mi__,
//      is__, k8s__, docker__, topology__) and registers it in a searchable
//      registry — unless it fails the write guardrail (R4.2), in which case
//      it is simply never registered and therefore never discoverable.
//   3. Answers discover_tools(query) by scoring the registry and returning the
//      matching tool manifests — this is the lazy-loading / semantic-router
//      entry point (see mcp best practices Patterns 2, 3, 6).
//   4. Routes tools/call to the right backend by stripping the namespace prefix
//      (see mcp_server.bal routeToolCall).
//
// N-backend design (Refactor R4, todo/phase-3-mcp.md): backends are declared
// once in backendDefs() as data, not one hardcoded client var + getter pair
// per backend. Splunk and Datadog are the only REQUIRED backends (the demo's
// mock-first path); everything else defaults to disabled ("") and federates
// itself in — or self-heals back in — the moment its URL is configured.

import ballerina/http;
import ballerina/log;
import ballerina/time;

// ── Backend MCP URLs — set in Config.toml; env vars override at runtime ───────
// Splunk/Datadog keep their original names/defaults (back-compat with the
// existing mock-first demo). New backends default to "" — disabled — until an
// operator points them at a real or mock MCP server.
configurable string splunkMcpUrl  = "http://splunk-mock-mcp:8400";
configurable string datadogMcpUrl = "http://datadog-mock-mcp:8401";
configurable string apimMcpUrl    = "";
configurable string miMcpUrl      = "";
configurable string isMcpUrl      = "";
configurable string k8sMcpUrl     = "";
configurable string dockerMcpUrl  = "";

// Include toggles (env INCLUDE_WSO2_MCP / INCLUDE_K8S_MCP, Y|N). A hard on/off
// gate above the per-backend URL check: when N, that whole group of backends is
// dropped from the federation table entirely — never connected, discovered, or
// routed — regardless of whether its <LABEL>_MCP_URL is set. splunk/datadog
// (the required observability backends) are never gated. Defaults preserve the
// prior behavior: WSO2 group on, k8s group off (it was already infra-mcp opt-in).
configurable boolean includeWso2Mcp = true;
configurable boolean includeK8sMcp  = false;

isolated function wso2McpIncluded() returns boolean => envOrBool("INCLUDE_WSO2_MCP", includeWso2Mcp);
isolated function k8sMcpIncluded() returns boolean => envOrBool("INCLUDE_K8S_MCP", includeK8sMcp);

const decimal FEDERATION_CONNECT_TIMEOUT_SECS = 10;
const int FEDERATION_RETRY_INTERVAL_SECS = 15;

// A registry entry is a namespaced tool manifest the agent can be handed.
type RegistryEntry record {|
    string name;
    string description;
    json inputSchema;
|};

// One row of the backend table. allowTools/denyTools are the write guardrail:
// a tool failing isToolAllowed() is never registered, hence never
// discoverable or callable by the agent — see R4.2 in todo/phase-3-mcp.md.
type BackendDef record {|
    string label;
    string envKey;
    string defaultUrl;       // "" = disabled unless env/Config.toml overrides it
    boolean required = false; // only splunk/datadog — reserved for future use
    string[] allowTools = []; // empty = allow everything not denied
    string[] denyTools = [];  // exact name or a single leading/trailing "*" glob
|};

// The backend table. Per-label env overrides `<LABEL>_MCP_ALLOW`/`_DENY`
// (comma-separated glob patterns) are merged in at read time.
isolated function backendDefs() returns BackendDef[] {
    // splunk/datadog are always present (required). The WSO2 group (apim/mi/is)
    // and the infra group (k8s/docker) are each gated by an include toggle, so
    // N drops them from the table wholesale — see wso2McpIncluded/k8sMcpIncluded.
    BackendDef[] base = [
        {label: "splunk", envKey: "SPLUNK_MCP_URL", defaultUrl: splunkMcpUrl, required: true},
        {label: "datadog", envKey: "DATADOG_MCP_URL", defaultUrl: datadogMcpUrl, required: true}
    ];
    if wso2McpIncluded() {
        base.push(
            {label: "apim", envKey: "APIM_MCP_URL", defaultUrl: apimMcpUrl},
            {label: "mi", envKey: "MI_MCP_URL", defaultUrl: miMcpUrl},
            {label: "is", envKey: "IS_MCP_URL", defaultUrl: isMcpUrl}
        );
    }
    if k8sMcpIncluded() {
        base.push(
            {label: "k8s", envKey: "K8S_MCP_URL", defaultUrl: k8sMcpUrl,
             denyTools: ["pods_delete", "pods_exec", "pods_run", "resources_delete", "resources_create_or_update", "helm_*"]},
            {label: "docker", envKey: "DOCKER_MCP_URL", defaultUrl: dockerMcpUrl,
             allowTools: ["list_*", "*_list", "get_*", "inspect_*", "logs*", "docker_info"]}
        );
    }
    BackendDef[] merged = [];
    foreach BackendDef d in base {
        string[] extraAllow = envList(d.label.toUpperAscii() + "_MCP_ALLOW");
        string[] extraDeny = envList(d.label.toUpperAscii() + "_MCP_DENY");
        merged.push({
            label: d.label,
            envKey: d.envKey,
            defaultUrl: d.defaultUrl,
            required: d.required,
            allowTools: [...d.allowTools, ...extraAllow],
            denyTools: [...d.denyTools, ...extraDeny]
        });
    }
    return merged;
}

isolated function isKnownBackendLabel(string label) returns boolean {
    foreach BackendDef def in backendDefs() {
        if def.label == label {
            return true;
        }
    }
    return false;
}

// ── Write guardrail (R4.2) ────────────────────────────────────────────────────

isolated function isToolAllowed(BackendDef def, string realName) returns boolean {
    foreach string pat in def.denyTools {
        if matchesPattern(realName, pat) {
            return false;
        }
    }
    if def.allowTools.length() == 0 {
        return true;
    }
    foreach string pat in def.allowTools {
        if matchesPattern(realName, pat) {
            return true;
        }
    }
    return false;
}

isolated function matchesPattern(string name, string pattern) returns boolean {
    if pattern.length() >= 2 && pattern.startsWith("*") && pattern.endsWith("*") {
        return name.includes(pattern.substring(1, pattern.length() - 1));
    }
    if pattern.endsWith("*") {
        return name.startsWith(pattern.substring(0, pattern.length() - 1));
    }
    if pattern.startsWith("*") {
        return name.endsWith(pattern.substring(1));
    }
    return name == pattern;
}

// ── Registry state (isolated + lock, matching runbooks.bal) ──────────────────

isolated map<RegistryEntry> toolRegistry = {};

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

isolated function registryHas(string name) returns boolean {
    lock {
        return toolRegistry.hasKey(name);
    }
}

// ── Backend connection state — map-based, N backends (R4.1) ──────────────────

isolated map<http:Client> backendClients = {};
isolated map<string> backendUrls = {};
isolated map<boolean> backendConnected = {};
isolated map<int> backendLastAttempt = {};

isolated function getBackend(string label) returns http:Client? {
    lock {
        return backendClients[label];
    }
}

isolated function setBackend(string label, http:Client c) {
    lock {
        backendClients[label] = c;
    }
}

isolated function isBackendConnected(string label) returns boolean {
    lock {
        return backendConnected[label] ?: false;
    }
}

isolated function markConnected(string label) {
    lock {
        backendConnected[label] = true;
    }
}

isolated function backendUrlFor(string label) returns string? {
    lock {
        return backendUrls[label];
    }
}

isolated function setBackendUrl(string label, string url) {
    lock {
        backendUrls[label] = url;
    }
}

isolated function lastAttempt(string label) returns int {
    lock {
        return backendLastAttempt[label] ?: 0;
    }
}

isolated function recordAttempt(string label, int nowSecs) {
    lock {
        backendLastAttempt[label] = nowSecs;
    }
}

isolated function connectedBackendLabels() returns string[] {
    lock {
        return backendConnected.keys().clone();
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
         inputSchema: {'type: "object", properties: {}}},
        {name: "topology__suggest_runbooks",
         description: "[runbook] Rank the top-3 applicable runbooks for a service given a free-text diagnosis, with rationale and risk.",
         inputSchema: {'type: "object",
             properties: {'service: {'type: "string"}, diagnosis: {'type: "string"}},
             required: ["service", "diagnosis"]}},
        {name: "topology__health_report",
         description: "[skill] Aggregate health across the mesh and every federated WSO2-product backend into one report. Optional product filter (e.g. \"apim\", \"mi\", \"is\", or a service name).",
         inputSchema: {'type: "object", properties: {product: {'type: "string"}}}},
        {name: "topology__top_issues",
         description: "[skill] Rank the top issues across mesh health, Datadog, Splunk, and federated WSO2/k8s backends. Optional count (default 5, max 20) and product filter.",
         inputSchema: {'type: "object", properties: {count: {'type: "integer"}, product: {'type: "string"}}}},
        {name: "topology__list_deployments",
         description: "[skill] List the known deployment cache — mesh services plus the three WSO2 products, with product/version/environment.",
         inputSchema: {'type: "object", properties: {}}}
    ];
}

// The discover_tools manifest — the one lazy-loading entry point advertised in
// tools/list alongside the topology tools. Description is composed at call
// time from whichever backends are currently federated (R4.3).
isolated function discoverToolDef() returns json {
    string[] labels = connectedBackendLabels();
    string labelList = labels.length() > 0 ? joinComma(labels) : "none yet — try again shortly";
    return {
        name: "discover_tools",
        description: "Search for backend tools by capability and get their schemas so you can call them. " +
            "Call this before using ANY tool whose prefix is not topology__. " +
            string `Currently federated backends: ${labelList}. ` +
            "Examples: \"Splunk log query\", \"Datadog metric trace APM\", \"Datadog monitor error tracking\", " +
            "\"kubernetes pods events\", \"APIM api list gateway status\", " +
            "\"integration proxy services message processors\", \"identity server users health\".",
        inputSchema: {
            'type: "object",
            properties: {
                query: {'type: "string",
                    description: "Natural language description of the capability needed (e.g. \"Splunk logs query\", \"kubernetes pod list\", \"APIM gateway status\")."}
            },
            required: ["query"]
        }
    };
}

isolated function joinComma(string[] items) returns string {
    if items.length() == 0 {
        return "";
    }
    string result = items[0];
    int i = 1;
    while i < items.length() {
        result = result + ", " + items[i];
        i += 1;
    }
    return result;
}

isolated function splitCsv(string s) returns string[] {
    string[] result = [];
    string remaining = s;
    while remaining.length() > 0 {
        int? commaIdx = remaining.indexOf(",");
        string part;
        if commaIdx is int {
            part = remaining.substring(0, commaIdx);
            remaining = remaining.substring(commaIdx + 1);
        } else {
            part = remaining;
            remaining = "";
        }
        string trimmed = part.trim();
        if trimmed != "" {
            result.push(trimmed);
        }
    }
    return result;
}

isolated function envList(string key) returns string[] {
    string v = envOr(key, "");
    return v.trim() == "" ? [] : splitCsv(v);
}

// ── Lazy federation ───────────────────────────────────────────────────────────
// Registers topology tools (no network) and connects every configured
// backend, registering their namespaced tools. Non-fatal: a backend that is
// down (or simply disabled, defaultUrl == "") is skipped and retried on a
// later call (bounded by FEDERATION_RETRY_INTERVAL_SECS) until it connects.
// There is no all-or-nothing readiness latch — a down OPTIONAL backend never
// blocks topology tools or any already-connected backend.

function ensureFederation() {
    // Topology tools need no network — always (re-)register them.
    foreach RegistryEntry e in topologyToolDefs() {
        registerTool(e);
    }

    int nowSecs = <int>time:utcNow()[0];
    foreach BackendDef def in backendDefs() {
        string url = envOrCfg(def.envKey, def.defaultUrl);
        if url.trim() == "" {
            continue; // backend disabled — nothing to do
        }
        if isBackendConnected(def.label) {
            continue; // already federated
        }
        int last = lastAttempt(def.label);
        if last != 0 && (nowSecs - last) < FEDERATION_RETRY_INTERVAL_SECS {
            continue; // back-off window — avoid hammering a down backend
        }
        http:Client? c = connectBackend(def, url);
        if c is http:Client {
            setBackend(def.label, c);
            setBackendUrl(def.label, url);
            markConnected(def.label);
        } else {
            recordAttempt(def.label, nowSecs);
        }
    }
}

// Connect to one backend, list its tools, and register the ones that pass the
// write guardrail (R4.2), namespaced under "<label>__". Returns () (with a
// warning) if the backend is unreachable — never fatal, always retried later.
function connectBackend(BackendDef def, string url) returns http:Client? {
    http:Client|error c = new (url, timeout = FEDERATION_CONNECT_TIMEOUT_SECS);
    if c is error {
        log:printWarn("MCP backend client construction failed", label = def.label, url = url, 'error = c);
        return ();
    }
    error? initErr = mcpInitialize(c);
    if initErr is error {
        log:printWarn("MCP backend initialize failed — will retry on next call", label = def.label, url = url, 'error = initErr);
        return ();
    }
    McpToolDef[]|error tools = mcpListTools(c);
    if tools is error {
        log:printWarn("MCP backend tools/list failed", label = def.label, url = url, 'error = tools);
        return ();
    }
    string prefix = def.label + "__";
    string tag = "[" + def.label + "]";
    int registered = 0;
    int filtered = 0;
    foreach McpToolDef t in tools {
        if !isToolAllowed(def, t.name) {
            filtered += 1;
            continue;
        }
        registerTool({name: prefix + t.name, description: tag + " " + t.description, inputSchema: t.inputSchema});
        registered += 1;
    }
    log:printInfo("federated MCP backend", label = def.label, url = url, registered = registered, filtered = filtered);
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
    RegistryEntry[] found = searchRegistry(snapshotRegistry(), query, 8);
    if found.length() == 0 {
        return string `No tools matched "${query}". Try: "Splunk logs query", "Datadog metric trace APM monitor", "kubernetes pods", "APIM api list", or "topology service dependency runbook correlate".`;
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
// A query word that names a backend label directly (e.g. "apim", "k8s") gets
// an extra +3 boost on tools carrying that label's "[label]" tag, so a growing
// tool count doesn't bury label-specific queries (see risk table in the plan).
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
        if haystack.includes("[" + word + "]")  {
            score += 3;
        } else if haystack.includes(word) {
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
