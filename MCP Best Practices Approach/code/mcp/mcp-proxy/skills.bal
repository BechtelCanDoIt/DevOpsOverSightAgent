// Phase 7.3/7.4 — server-side aggregation "skills": health_report and
// top_issues fan out across every federated backend so the agent (or a
// chat command / dedicated HTTP endpoint — Phase 4 §4.9) gets one call
// instead of re-investigating from scratch every time.

import ballerina/http;
import ballerina/lang.value;
import ballerina/time;

// Safe field extraction from a json value of uncertain shape (mock-server
// responses parsed back from text) — returns fallback rather than using
// `check`, since these helpers are called from functions with no error in
// their return type.
isolated function jsonStringField(json obj, string fieldName, string fallback) returns string {
    if obj is map<json> {
        json? v = obj[fieldName];
        if v is string {
            return v;
        }
        if v is int || v is decimal || v is boolean {
            return v.toString();
        }
    }
    return fallback;
}

isolated function jsonIntField(json obj, string fieldName, int fallback) returns int {
    if obj is map<json> {
        json? v = obj[fieldName];
        if v is int {
            return v;
        }
    }
    return fallback;
}

// ── Shared probe, refactored out of dispatchTool's get_service_health so
// health_report can reuse the exact same live check (Phase 7.3). ────────────

type ServiceHealthProbe record {|
    string 'service;
    string status; // UP | DEGRADED | DOWN | UNKNOWN (client couldn't even be built)
    int? httpStatus;
    string? errorMsg;
|};

isolated function probeServiceHealth(ServiceInfo svc) returns ServiceHealthProbe {
    http:Client|error hc = new (svc.healthEndpoint, timeout = 3);
    if hc is error {
        return {'service: svc.name, status: "UNKNOWN", httpStatus: (), errorMsg: ()};
    }
    http:Response|error r = hc->get("/");
    if r is error {
        return {'service: svc.name, status: "DOWN", httpStatus: (), errorMsg: r.message()};
    }
    return {'service: svc.name, status: r.statusCode == 200 ? "UP" : "DEGRADED", httpStatus: r.statusCode, errorMsg: ()};
}

// ── 7.3 topology__health_report ──────────────────────────────────────────────

type HealthSection record {|
    string 'source;
    string status; // HEALTHY | DEGRADED | CRITICAL | UNAVAILABLE | UNKNOWN
    string summary;
    json details;
|};

function healthReport(string? product) returns json {
    future<HealthSection>[] futures = [];
    foreach string svcName in listAllServices() {
        if !productMatches(product, "mesh", svcName) {
            continue;
        }
        ServiceInfo? svc = catalogLookup(svcName);
        if svc is ServiceInfo {
            future<HealthSection> f = start probeMeshSection(svc);
            futures.push(f);
        }
    }
    foreach DeploymentInfo d in listDeployments() {
        if d.healthTool == "" {
            continue; // mesh entries already handled above
        }
        if !productMatches(product, d.product, d.name) {
            continue;
        }
        future<HealthSection> f = start probeProductSection(d);
        futures.push(f);
    }

    HealthSection[] sections = [];
    foreach future<HealthSection> f in futures {
        HealthSection|error r = wait f;
        if r is HealthSection {
            sections.push(r);
        }
    }
    return {overall: computeOverall(sections), generatedAt: time:utcToString(time:utcNow()), sections: sections.toJson()};
}

isolated function probeMeshSection(ServiceInfo svc) returns HealthSection {
    ServiceHealthProbe p = probeServiceHealth(svc);
    string status = p.status == "UP" ? "HEALTHY" :
        p.status == "DEGRADED" ? "DEGRADED" :
        p.status == "DOWN" ? "CRITICAL" : "UNKNOWN";
    return {'source: svc.name, status: status, summary: string `mesh probe: ${p.status}`,
        details: {httpStatus: p.httpStatus, 'error: p.errorMsg}};
}

// Not isolated: callBackendToolDirect performs network I/O via a shared
// (isolated-guarded) backend client.
function probeProductSection(DeploymentInfo d) returns HealthSection {
    if !isBackendConnected(d.product) {
        return {'source: d.name, status: "UNAVAILABLE", summary: string `${d.product} backend not connected`, details: {}};
    }
    string|error r = callBackendToolDirect(d.product, d.healthTool, {});
    if r is error {
        return {'source: d.name, status: "CRITICAL", summary: r.message(), details: {}};
    }
    json|error parsed = value:fromJsonString(r);
    string status = "HEALTHY";
    if parsed is json {
        json|error st = parsed.status;
        if st is json && st.toString() != "UP" {
            status = "DEGRADED";
        }
    }
    return {'source: d.name, status: status, summary: r, details: parsed is json ? parsed : {}};
}

// UNKNOWN only when every section is UNAVAILABLE/UNKNOWN (no live signal at
// all); otherwise CRITICAL beats DEGRADED beats HEALTHY.
isolated function computeOverall(HealthSection[] sections) returns string {
    boolean anyKnown = false;
    boolean anyCritical = false;
    boolean anyDegraded = false;
    foreach HealthSection s in sections {
        if s.status == "UNAVAILABLE" || s.status == "UNKNOWN" {
            continue;
        }
        anyKnown = true;
        if s.status == "CRITICAL" {
            anyCritical = true;
        } else if s.status == "DEGRADED" {
            anyDegraded = true;
        }
    }
    if !anyKnown {
        return "UNKNOWN";
    }
    if anyCritical {
        return "CRITICAL";
    }
    if anyDegraded {
        return "DEGRADED";
    }
    return "HEALTHY";
}

// product filter shared by health_report and top_issues: absent/empty means
// "include everything"; otherwise a case-insensitive substring match against
// either the source's backend-label tag or its display name.
isolated function productMatches(string? product, string tag, string name) returns boolean {
    if product is () || product.trim() == "" {
        return true;
    }
    string p = product.toLowerAscii();
    return tag.toLowerAscii().includes(p) || name.toLowerAscii().includes(p);
}

// ── 7.4 topology__top_issues ─────────────────────────────────────────────────

type Issue record {|
    string 'source;
    string severity; // P1 | P2 | P3
    string target;
    string title;
    string evidence;
    int score;
|};

function topIssues(int count, string? product) returns Issue[] {
    Issue[] issues = [];

    foreach string svcName in listAllServices() {
        if !productMatches(product, "mesh", svcName) {
            continue;
        }
        ServiceInfo? svc = catalogLookup(svcName);
        if svc is ServiceInfo {
            ServiceHealthProbe p = probeServiceHealth(svc);
            if p.status == "DOWN" {
                issues.push({'source: "mesh", severity: "P1", target: svc.name,
                    title: "service unreachable", evidence: p.errorMsg ?: "connection failed", score: 10});
            }
        }
    }

    if isBackendConnected("datadog") && productMatches(product, "datadog", "datadog") {
        appendDatadogIssues(issues);
    }
    if isBackendConnected("splunk") && productMatches(product, "splunk", "splunk") {
        appendSplunkIssues(issues);
    }
    if isBackendConnected("apim") && productMatches(product, "apim", "apim") {
        string|error r = callBackendToolDirect("apim", "apim_list_apis", {});
        if r is string {
            appendApimAnomalies(issues, r);
        }
    }
    if isBackendConnected("mi") && productMatches(product, "mi", "mi") {
        string|error r = callBackendToolDirect("mi", "mi_get_message_processors", {});
        if r is string {
            appendMiAnomalies(issues, r);
        }
    }
    if isBackendConnected("is") && productMatches(product, "is", "is") {
        string|error r = callBackendToolDirect("is", "is_user_store_status", {});
        if r is string {
            appendIsAnomalies(issues, r);
        }
    }
    if isBackendConnected("k8s") && productMatches(product, "k8s", "k8s") {
        // Best-effort only — this tool name/response shape was NOT verified
        // against a live cluster in this session (see
        // todo/phase-6-mcp-expansion.md §6.4). A missing/renamed tool, or a
        // differently-shaped event object, simply yields zero k8s issues
        // rather than failing top_issues as a whole.
        string|error r = callBackendToolDirect("k8s", "events_list", {});
        if r is string {
            appendK8sWarnings(issues, r);
        }
    }

    sortIssuesByScoreDesc(issues);
    int lim = capCount(count);
    if issues.length() <= lim {
        return issues;
    }
    return issues.slice(0, lim);
}

isolated function capCount(int requested) returns int {
    if requested < 0 {
        return 0;
    }
    return requested > 20 ? 20 : requested;
}

function appendDatadogIssues(Issue[] issues) {
    string|error monitorsR = callBackendToolDirect("datadog", "search_datadog_monitors", {});
    if monitorsR is string {
        json|error parsed = value:fromJsonString(monitorsR);
        if parsed is json[] {
            foreach json m in parsed {
                if jsonStringField(m, "status", "") == "Alert" {
                    string name = jsonStringField(m, "name", "unknown monitor");
                    string svcTag = extractServiceTag(m);
                    string severity = "P2";
                    ServiceInfo? svc = svcTag == "" ? () : catalogLookup(svcTag);
                    if svc is ServiceInfo && slaAtOrAbove999(svc.sla) {
                        severity = "P1";
                    }
                    issues.push({'source: "datadog", severity: severity, target: svcTag == "" ? name : svcTag,
                        title: string `alerting monitor: ${name}`, evidence: "status=Alert", score: 8});
                }
            }
        }
    }
    string|error errR = callBackendToolDirect("datadog", "search_datadog_error_tracking_issues", {});
    if errR is string {
        json|error parsed = value:fromJsonString(errR);
        if parsed is json[] {
            foreach json e in parsed {
                string title = jsonStringField(e, "title", "error tracking issue");
                string svc = jsonStringField(e, "service", "unknown-service");
                issues.push({'source: "datadog", severity: "P2", target: svc, title: title,
                    evidence: "error-tracking issue open", score: 6});
            }
        }
    }
}

isolated function extractServiceTag(json monitor) returns string {
    json|error tagsF = monitor.tags;
    if tagsF is json[] {
        foreach json t in tagsF {
            string ts = t.toString();
            if ts.startsWith("service:") {
                return ts.substring(8);
            }
        }
    }
    return "";
}

// Fixed catalog (catalog.bal SERVICE_CATALOG) only ever uses these four SLA
// strings — a plain set-membership check avoids pulling in a numeric-parsing
// lang module for a threshold this small and this static.
isolated function slaAtOrAbove999(string sla) returns boolean {
    return sla == "99.9%" || sla == "99.95%" || sla == "99.99%";
}

function appendSplunkIssues(Issue[] issues) {
    string|error r = callBackendToolDirect("splunk", "splunk_run_query", {query: "index=devops-poc error 502"});
    if r is string {
        json|error parsed = value:fromJsonString(r);
        if parsed is map<json> {
            json? countF = parsed["result_count"];
            int count = countF is int ? countF : 0;
            if count > 0 {
                int score = count / 10;
                if score > 7 {
                    score = 7;
                }
                issues.push({'source: "splunk", severity: "P3", target: "devops-poc",
                    title: "elevated error-status events", evidence: string `result_count=${count}`, score: score});
            }
        }
    }
}

function appendApimAnomalies(Issue[] issues, string apiListJson) {
    json|error parsed = value:fromJsonString(apiListJson);
    if parsed is json[] {
        foreach json a in parsed {
            if jsonStringField(a, "lifeCycleStatus", "") == "BLOCKED" {
                string name = jsonStringField(a, "name", "unknown API");
                issues.push({'source: "apim", severity: "P2", target: name,
                    title: "API blocked", evidence: "lifeCycleStatus=BLOCKED", score: 6});
            }
        }
    }
}

function appendMiAnomalies(Issue[] issues, string processorsJson) {
    json|error parsed = value:fromJsonString(processorsJson);
    if parsed is json[] {
        foreach json p in parsed {
            if jsonStringField(p, "state", "") == "INACTIVE" {
                string name = jsonStringField(p, "name", "unknown processor");
                int count = jsonIntField(p, "messageCount", -1);
                string evidence = count >= 0 ? string `messageCount=${count}` : "state=INACTIVE";
                issues.push({'source: "mi", severity: "P2", target: name,
                    title: "message processor inactive", evidence: evidence, score: 6});
            }
        }
    }
}

function appendIsAnomalies(Issue[] issues, string userStoresJson) {
    json|error parsed = value:fromJsonString(userStoresJson);
    if parsed is json[] {
        foreach json s in parsed {
            if jsonStringField(s, "status", "") == "Disconnected" {
                string name = jsonStringField(s, "name", "unknown store");
                issues.push({'source: "is", severity: "P2", target: name,
                    title: "user store disconnected", evidence: "status=Disconnected", score: 6});
            }
        }
    }
}

function appendK8sWarnings(Issue[] issues, string eventsJson) {
    json|error parsed = value:fromJsonString(eventsJson);
    if parsed is json[] {
        foreach json e in parsed {
            if jsonStringField(e, "type", "") == "Warning" {
                string reason = jsonStringField(e, "reason", "Warning event");
                string target = jsonStringField(e, "involvedObjectName", "unknown");
                issues.push({'source: "k8s", severity: "P3", target: target,
                    title: reason, evidence: "type=Warning", score: 4});
            }
        }
    }
}

isolated function sortIssuesByScoreDesc(Issue[] issues) {
    int sz = issues.length();
    int ii = 0;
    while ii < sz - 1 {
        int bestIdx = ii;
        int jj = ii + 1;
        while jj < sz {
            if issues[jj].score > issues[bestIdx].score {
                bestIdx = jj;
            }
            jj += 1;
        }
        if bestIdx != ii {
            Issue tmp = issues[ii];
            issues[ii] = issues[bestIdx];
            issues[bestIdx] = tmp;
        }
        ii += 1;
    }
}
