import ballerina/http;
import ballerina/time;

type RunbookDef record {|
    string id;
    string name;
    string description;
    string paramsSchema;
|};

final RunbookDef[] & readonly RUNBOOKS = [
    {id: "restart-service", name: "Restart Service",
     description: "Gracefully restarts a service. In K8s: kubectl rollout restart.",
     paramsSchema: "{\"type\":\"object\",\"properties\":{\"service\":{\"type\":\"string\"}},\"required\":[\"service\"]}"},
    {id: "clear-cache", name: "Clear Inventory Cache",
     description: "Flushes the Redis cache for inventory-service.",
     paramsSchema: "{\"type\":\"object\",\"properties\":{}}"},
    {id: "disable-chaos", name: "Disable Chaos",
     description: "Calls POST /chaos/reset on the target service to clear injected faults.",
     paramsSchema: "{\"type\":\"object\",\"properties\":{\"service\":{\"type\":\"string\"}},\"required\":[\"service\"]}"},
    {id: "freeze-deploys", name: "Freeze Deploys",
     description: "Sets a deploy-freeze flag to prevent new deployments during an incident.",
     paramsSchema: "{\"type\":\"object\",\"properties\":{\"reason\":{\"type\":\"string\"}},\"required\":[\"reason\"]}"}
];

isolated boolean deployFrozen = false;
isolated string deployFreezeReason = "";
isolated string[] auditLog = [];

isolated function appendAudit(string entry) { lock { auditLog.push(entry); } }
isolated function getAuditLog() returns string[] { lock { return auditLog.clone(); } }
isolated function isDeployFrozen() returns boolean { lock { return deployFrozen; } }
isolated function getDeployFreezeReason() returns string { lock { return deployFreezeReason; } }
isolated function listRunbooks() returns RunbookDef[] => RUNBOOKS;

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
        steps.push(string `[${ts}] kubectl rollout restart deployment/${svc} (stub)`);
        steps.push(string `[${ts}] restart-service complete`);
        appendAudit(string `${ts} RUNBOOK restart-service service=${svc}`);
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
