import ballerina/http;
import ballerina/time;

type RunbookDef record {|
    string id;
    string name;
    string description;
    string paramsSchema;
    // Phase 7.1 — metadata driving topology__suggest_runbooks' scoring, so
    // runbook selection isn't left entirely to unaided LLM judgment.
    string[] symptoms;
    string category; // "remediation" | "mitigation" | "diagnostic" | "process"
    int riskLevel;   // 1 (safe) .. 3 (risky) — higher = bigger scoring penalty
    boolean automatable;
|};

final RunbookDef[] & readonly RUNBOOKS = [
    {id: "restart-service", name: "Restart Service",
     description: "Gracefully restarts a service. In K8s: kubectl rollout restart.",
     paramsSchema: "{\"type\":\"object\",\"properties\":{\"service\":{\"type\":\"string\"}},\"required\":[\"service\"]}",
     symptoms: ["crash", "oom", "memory leak", "hang", "unresponsive", "stuck"],
     category: "remediation", riskLevel: 2, automatable: true},
    {id: "clear-cache", name: "Clear Inventory Cache",
     description: "Flushes the Redis cache for inventory-service.",
     paramsSchema: "{\"type\":\"object\",\"properties\":{}}",
     symptoms: ["cache", "stale data", "redis", "inconsistent reads"],
     category: "remediation", riskLevel: 1, automatable: true},
    {id: "disable-chaos", name: "Disable Chaos",
     description: "Calls POST /chaos/reset on the target service to clear injected faults.",
     paramsSchema: "{\"type\":\"object\",\"properties\":{\"service\":{\"type\":\"string\"}},\"required\":[\"service\"]}",
     symptoms: ["502", "error rate", "chaos", "fault injection", "latency spike"],
     category: "mitigation", riskLevel: 1, automatable: true},
    {id: "freeze-deploys", name: "Freeze Deploys",
     description: "Sets a deploy-freeze flag to prevent new deployments during an incident.",
     paramsSchema: "{\"type\":\"object\",\"properties\":{\"reason\":{\"type\":\"string\"}},\"required\":[\"reason\"]}",
     symptoms: ["deploy", "rollout", "release", "regression"],
     category: "process", riskLevel: 1, automatable: false},
    {id: "scale-service", name: "Scale Service",
     description: "Adjusts a Kubernetes Deployment's replica count to absorb load. K8s-only — stub unless a k8s backend is connected and writes are enabled.",
     paramsSchema: "{\"type\":\"object\",\"properties\":{\"service\":{\"type\":\"string\"},\"replicas\":{\"type\":\"integer\"}},\"required\":[\"service\",\"replicas\"]}",
     symptoms: ["high load", "cpu saturation", "throughput", "queue depth", "capacity", "traffic spike"],
     category: "mitigation", riskLevel: 2, automatable: true}
];

// Gate for any runbook step that mutates real infrastructure (k8s rollout
// restart / scale). Off by default — every write path below falls back to a
// stub unless this is explicitly turned on, matching the "reads federate,
// writes only via runbooks" guardrail's own cautious default.
configurable boolean k8sWriteEnabled = false;
configurable string restartContainerPrefix = "devops-poc-";

isolated boolean deployFrozen = false;
isolated string deployFreezeReason = "";
isolated string[] auditLog = [];

isolated function appendAudit(string entry) { lock { auditLog.push(entry); } }
isolated function getAuditLog() returns string[] { lock { return auditLog.clone(); } }
isolated function isDeployFrozen() returns boolean { lock { return deployFrozen; } }
isolated function getDeployFreezeReason() returns string { lock { return deployFreezeReason; } }
isolated function listRunbooks() returns RunbookDef[] => RUNBOOKS;

isolated function findRunbook(string id) returns RunbookDef? {
    foreach RunbookDef rb in RUNBOOKS {
        if rb.id == id {
            return rb;
        }
    }
    return ();
}

function executeRunbook(string id, map<string> params) returns string[]|error {
    string[] steps = [];
    string ts = time:utcToString(time:utcNow());
    if id == "disable-chaos" {
        string svc = params["service"] ?: "unknown-service";
        string host = svc.endsWith("-service") ? svc.substring(0, svc.length() - 8) : svc;
        string url = string `http://${host}:9099`;
        steps.push(string `[${ts}] POST ${url}/chaos/reset`);
        http:Client|error cc = new (url, timeout = 5);
        if cc is http:Client {
            http:Response|error r = cc->post("/chaos/reset", (), {
                "X-Chaos-Token": envOr("CHAOS_TOKEN", "dev-chaos-token")});
            steps.push(r is http:Response ? string `[${ts}] HTTP ${r.statusCode}` :
                string `[${ts}] call failed: ${(<error>r).message()}`);
        } else {
            steps.push(string `[${ts}] Could not connect to ${url}`);
        }
        steps.push(string `[${ts}] disable-chaos complete for ${svc}`);
        appendAudit(string `${ts} RUNBOOK disable-chaos service=${svc}`);
    } else if id == "clear-cache" {
        steps.push(string `[${ts}] flush Redis at ${envOr("REDIS_HOST","redis")}:6379 (stub)`);
        steps.push(string `[${ts}] clear-cache complete`);
        appendAudit(string `${ts} RUNBOOK clear-cache`);
    } else if id == "restart-service" {
        string svc = params["service"] ?: "unknown-service";
        string path = restartServiceReal(svc, steps, ts);
        steps.push(string `[${ts}] restart-service complete (path=${path})`);
        appendAudit(string `${ts} RUNBOOK restart-service service=${svc} path=${path}`);
    } else if id == "scale-service" {
        string svc = params["service"] ?: "unknown-service";
        string replicasStr = params["replicas"] ?: "1";
        string path = scaleServiceReal(svc, replicasStr, steps, ts);
        steps.push(string `[${ts}] scale-service complete (path=${path})`);
        appendAudit(string `${ts} RUNBOOK scale-service service=${svc} replicas=${replicasStr} path=${path}`);
    } else if id == "freeze-deploys" {
        string reason = params["reason"] ?: "incident in progress";
        lock { deployFrozen = true; }
        lock { deployFreezeReason = reason; }
        steps.push(string `[${ts}] Deploy freeze activated: ${reason}`);
        appendAudit(string `${ts} RUNBOOK freeze-deploys reason=${reason}`);
    } else {
        return error(string `Unknown runbook id: ${id}`);
    }
    return steps;
}

// Real restart-service (Phase 7.2). Tries a connected docker backend first
// (restart_container — a name-pattern the write guardrail's docker allowlist
// deliberately does NOT include, so this can only ever run through this
// direct path, never from an agent tool call), then a connected k8s backend
// gated behind k8sWriteEnabled (also guardrail-filtered by design — see
// federation.bal's k8s denyTools), and only falls back to the pre-existing
// stub if neither applies or either call errors. Returns which path ran, for
// the audit log.
function restartServiceReal(string svc, string[] steps, string ts) returns string {
    if isBackendConnected("docker") {
        string shortName = svc.endsWith("-service") ? svc.substring(0, svc.length() - 8) : svc;
        string container = string `${envOrCfg("RESTART_CONTAINER_PREFIX", restartContainerPrefix)}${shortName}-1`;
        string|error r = callBackendToolDirect("docker", "restart_container", {name: container});
        if r is string {
            steps.push(string `[${ts}] docker restart_container ${container}: ${r}`);
            return "docker";
        }
        steps.push(string `[${ts}] docker restart failed: ${r.message()} — falling back`);
    }
    if isBackendConnected("k8s") && envOrBool("K8S_WRITE_ENABLED", k8sWriteEnabled) {
        // A real kubectl rollout restart patches the deployment's pod
        // template with a fresh annotation. Not verified against a live
        // cluster in this session (see todo/phase-6-mcp-expansion.md §6.4) —
        // off by default via k8sWriteEnabled, so this never runs in the demo
        // path unless an operator deliberately opts in with a real cluster.
        json patch = {apiVersion: "apps/v1", kind: "Deployment", metadata: {name: svc},
            spec: {template: {metadata: {annotations: {"devops-poc/restartedAt": ts}}}}};
        string|error r = callBackendToolDirect("k8s", "resources_create_or_update", {'resource: patch.toJsonString()});
        if r is string {
            steps.push(string `[${ts}] k8s resources_create_or_update deployment/${svc}: ${r}`);
            return "k8s";
        }
        steps.push(string `[${ts}] k8s restart failed: ${r.message()} — falling back to stub`);
    }
    steps.push(string `[${ts}] kubectl rollout restart deployment/${svc} (stub)`);
    return "stub";
}

// Real scale-service (Phase 7.1's new runbook) — same k8s-only, write-enabled
// gate and same "not live-verified" caveat as restartServiceReal above.
function scaleServiceReal(string svc, string replicasStr, string[] steps, string ts) returns string {
    if isBackendConnected("k8s") && envOrBool("K8S_WRITE_ENABLED", k8sWriteEnabled) {
        json patch = {apiVersion: "apps/v1", kind: "Deployment", metadata: {name: svc},
            spec: {replicas: replicasStr}};
        string|error r = callBackendToolDirect("k8s", "resources_create_or_update", {'resource: patch.toJsonString()});
        if r is string {
            steps.push(string `[${ts}] k8s resources_create_or_update deployment/${svc} replicas=${replicasStr}: ${r}`);
            return "k8s";
        }
        steps.push(string `[${ts}] k8s scale failed: ${r.message()} — falling back to stub`);
    }
    steps.push(string `[${ts}] kubectl scale deployment/${svc} --replicas=${replicasStr} (stub)`);
    return "stub";
}

// ── 7.1 topology__suggest_runbooks ───────────────────────────────────────────
// Scores every runbook applicable to a service against a free-text diagnosis,
// so runbook selection stops being pure unaided LLM judgment. See
// todo/phase-7-skills-runbooks.md §7.1 for the scoring breakdown.

type RunbookSuggestion record {|
    string id;
    string name;
    int score;
    int riskLevel;
    boolean automatable;
    string rationale;
    string paramsSchema;
|};

function suggestRunbooks(string serviceName, string diagnosis) returns RunbookSuggestion[] {
    ServiceInfo? svc = catalogLookup(serviceName);
    string[] listedIds = svc is ServiceInfo ? svc.runbookIds : [];

    [RunbookDef, int, boolean][] candidates = [];
    foreach RunbookDef rb in RUNBOOKS {
        boolean listed = isListed(listedIds, rb.id);
        if !listed && rb.category != "process" {
            continue; // applicability filter — not offered for this service
        }
        int score = scoreRunbookMatch(rb, diagnosis);
        if listed {
            score += 4;
        }
        if rb.automatable {
            score += 2;
        }
        score -= 2 * (rb.riskLevel - 1);
        candidates.push([rb, score, listed]);
    }

    // Selection sort desc by score; tie-break lower riskLevel first (mirrors
    // the pattern already used in federation.bal's searchRegistry).
    int sz = candidates.length();
    int ii = 0;
    while ii < sz - 1 {
        int bestIdx = ii;
        int jj = ii + 1;
        while jj < sz {
            int bestScore = candidates[bestIdx][1];
            int jScore = candidates[jj][1];
            boolean better = jScore > bestScore ||
                (jScore == bestScore && candidates[jj][0].riskLevel < candidates[bestIdx][0].riskLevel);
            if better {
                bestIdx = jj;
            }
            jj += 1;
        }
        if bestIdx != ii {
            [RunbookDef, int, boolean] tmp = candidates[ii];
            candidates[ii] = candidates[bestIdx];
            candidates[bestIdx] = tmp;
        }
        ii += 1;
    }

    RunbookSuggestion[] result = [];
    int lim = candidates.length() < 3 ? candidates.length() : 3;
    int idx = 0;
    while idx < lim {
        RunbookDef rb = candidates[idx][0];
        int score = candidates[idx][1];
        boolean listed = candidates[idx][2];
        result.push({
            id: rb.id, name: rb.name, score: score, riskLevel: rb.riskLevel, automatable: rb.automatable,
            rationale: rationaleFor(rb, diagnosis, listed),
            paramsSchema: rb.paramsSchema
        });
        idx += 1;
    }
    return result;
}

isolated function isListed(string[] listedIds, string id) returns boolean {
    foreach string l in listedIds {
        if l == id {
            return true;
        }
    }
    return false;
}

isolated function rationaleFor(RunbookDef rb, string diagnosis, boolean listed) returns string {
    string[] parts = [];
    foreach string sym in rb.symptoms {
        if diagnosis.toLowerAscii().includes(sym) {
            parts.push(sym);
        }
    }
    string symptomPart = parts.length() > 0 ? string `matched symptoms: ${", ".join(...parts)}` : "no direct symptom match";
    string catalogPart = listed ? "listed for this service" : "process runbook (always eligible)";
    string autoPart = rb.automatable ? "automatable" : "manual-only";
    return string `${symptomPart}; ${catalogPart}; ${autoPart}; risk=${rb.riskLevel}`;
}

// +3 exact symptom-word match, +2 name/description substring match, +1
// five-char-stem match (mirrors federation.bal's scoreToolMatch tiering).
isolated function scoreRunbookMatch(RunbookDef rb, string diagnosis) returns int {
    string symptomsJoined = " " + " ".join(...rb.symptoms);
    string haystackSymptoms = symptomsJoined.toLowerAscii();
    string haystackAll = (rb.name + " " + rb.description + symptomsJoined).toLowerAscii();
    int score = 0;
    string remaining = diagnosis.toLowerAscii();
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
        if containsExactWord(haystackSymptoms, word) {
            score += 3;
        } else if haystackAll.includes(word) {
            score += 2;
        } else if word.length() >= 5 && haystackAll.includes(word.substring(0, 4)) {
            score += 1;
        }
    }
    return score;
}

isolated function containsExactWord(string haystack, string word) returns boolean {
    string remaining = haystack.trim();
    while remaining.length() > 0 {
        int? spaceIdx = remaining.indexOf(" ");
        string token;
        if spaceIdx is int {
            token = remaining.substring(0, spaceIdx);
            remaining = remaining.substring(spaceIdx + 1).trim();
        } else {
            token = remaining;
            remaining = "";
        }
        if token == word {
            return true;
        }
    }
    return false;
}
