isolated function buildDatadogTraceUrl(string traceId, string ddSite) returns string =>
    string `https://app.${ddSite}/apm/trace/${traceId}`;

isolated function buildSplunkSpl(string traceId) returns string =>
    string `index=* trace_id="${traceId}" | table _time, service, trace_id, span_id, message | sort -_time`;

isolated function buildSplunkSearchUrl(string traceId, string splunkUrl) returns string {
    string spl = buildSplunkSpl(traceId);
    string s1 = re` `.replaceAll(spl, "%20");
    string s2 = re`"`.replaceAll(s1, "%22");
    string s3 = re`\*`.replaceAll(s2, "%2A");
    string encoded = re`=`.replaceAll(s3, "%3D");
    return string `${splunkUrl}/search?q=${encoded}`;
}

final string DEMO_TRACE_ID = "abc123def456789012345678deadbeef";
final string[] & readonly DEMO_TRACE_SERVICES = ["order-service", "customer-service", "inventory-service", "payment-service"];

isolated function inferInvolvedServices(string traceId) returns string[] =>
    traceId == DEMO_TRACE_ID ? DEMO_TRACE_SERVICES.clone() : [];

type DeployRecord record {|
    string 'service;
    string 'version;
    string deployedAt;
    string deployedBy;
    string gitSha;
    string status;
|};

final DeployRecord[] & readonly DEPLOY_LOG = [
    {'service: "payment-service", 'version: "1.2.3", deployedAt: "2026-06-08T09:00:00Z", deployedBy: "ci-bot", gitSha: "abc123", status: "success"},
    {'service: "order-service", 'version: "2.1.0", deployedAt: "2026-06-07T14:30:00Z", deployedBy: "ci-bot", gitSha: "def456", status: "success"},
    {'service: "inventory-service", 'version: "1.5.1", deployedAt: "2026-06-06T10:00:00Z", deployedBy: "ci-bot", gitSha: "ghi789", status: "success"}
];

isolated function findRecentDeploys(string serviceName, int _lookbackMinutes) returns DeployRecord[] {
    DeployRecord[] results = [];
    foreach DeployRecord d in DEPLOY_LOG { if d.'service == serviceName { results.push(d); } }
    return results;
}

type IncidentRecord record {|
    string id;
    string 'service;
    string title;
    string severity;
    string occurredAt;
    string rootCause;
    string resolution;
|};

final IncidentRecord[] & readonly INCIDENT_HISTORY = [
    {id: "INC-001", 'service: "payment-service", title: "payment-service 502 spike", severity: "P1", occurredAt: "2026-05-15T03:00:00Z", rootCause: "chaos injection left enabled after load test", resolution: "disable-chaos runbook"},
    {id: "INC-002", 'service: "inventory-service", title: "inventory cache cold-start latency", severity: "P2", occurredAt: "2026-05-20T11:00:00Z", rootCause: "Redis OOM caused eviction", resolution: "clear-cache + Redis maxmemory increase"},
    {id: "INC-003", 'service: "order-service", title: "order creation 500s", severity: "P1", occurredAt: "2026-06-01T08:00:00Z", rootCause: "payment-service returning 502 caused order rollback", resolution: "Restarted payment-service"}
];

isolated function findRelatedIncidents(string serviceName, int _lookbackDays) returns IncidentRecord[] {
    IncidentRecord[] results = [];
    foreach IncidentRecord i in INCIDENT_HISTORY { if i.'service == serviceName { results.push(i); } }
    return results;
}
