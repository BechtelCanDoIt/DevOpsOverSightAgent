// Service catalog — static map. Production: read from CMDB. All 7 mesh services
// with dependency edges matching phase-2-ballerina.md exactly.

type ServiceInfo record {|
    string name;
    string owner;
    string slackChannel;
    string repoUrl;
    string healthEndpoint;
    string[] dependencies;
    string[] runbookIds;
    string sla;
|};

final map<ServiceInfo> & readonly SERVICE_CATALOG = {
    "store-service": {
        name: "store-service", owner: "store-team", slackChannel: "#store",
        repoUrl: "https://github.com/devopspoc/store-service",
        healthEndpoint: "http://store:9090/health",
        dependencies: ["inventory-service"],
        runbookIds: ["restart-service", "disable-chaos"], sla: "99.9%"
    },
    "customer-service": {
        name: "customer-service", owner: "customer-team", slackChannel: "#customer",
        repoUrl: "https://github.com/devopspoc/customer-service",
        healthEndpoint: "http://customer:9090/health",
        dependencies: [],
        runbookIds: ["restart-service", "disable-chaos"], sla: "99.95%"
    },
    "order-service": {
        name: "order-service", owner: "order-team", slackChannel: "#order",
        repoUrl: "https://github.com/devopspoc/order-service",
        healthEndpoint: "http://order:9090/health",
        dependencies: ["customer-service", "inventory-service", "payment-service", "invoice-service", "notification-service"],
        runbookIds: ["restart-service", "disable-chaos", "freeze-deploys"], sla: "99.9%"
    },
    "inventory-service": {
        name: "inventory-service", owner: "inventory-team", slackChannel: "#inventory",
        repoUrl: "https://github.com/devopspoc/inventory-service",
        healthEndpoint: "http://inventory:9090/health",
        dependencies: [],
        runbookIds: ["restart-service", "disable-chaos", "clear-cache"], sla: "99.9%"
    },
    "invoice-service": {
        name: "invoice-service", owner: "finance-team", slackChannel: "#finance",
        repoUrl: "https://github.com/devopspoc/invoice-service",
        healthEndpoint: "http://invoice:9090/health",
        dependencies: [],
        runbookIds: ["restart-service", "disable-chaos"], sla: "99.5%"
    },
    "payment-service": {
        name: "payment-service", owner: "payments-team", slackChannel: "#payments",
        repoUrl: "https://github.com/devopspoc/payment-service",
        healthEndpoint: "http://payment:9090/health",
        dependencies: [],
        runbookIds: ["restart-service", "disable-chaos"], sla: "99.99%"
    },
    "notification-service": {
        name: "notification-service", owner: "platform-team", slackChannel: "#platform",
        repoUrl: "https://github.com/devopspoc/notification-service",
        healthEndpoint: "http://notification:9090/health",
        dependencies: [],
        runbookIds: ["restart-service", "disable-chaos"], sla: "99.5%"
    }
};

// Async edges — order→notification via NATS (not in sync dependencies above).
final map<string[]> & readonly ASYNC_EDGES = {
    "order-service": ["notification-service"]
};

// Phase 7.5 — deployment cache backing topology__list_deployments. product
// matches a BackendDef label (federation.bal) for the three WSO2 products;
// "mesh" entries have no healthTool since they're probed via ServiceInfo's
// own healthEndpoint (see skills.bal probeServiceHealth), not a backend tool.
type DeploymentInfo record {|
    string name;
    string product;
    string 'version;
    string environment;
    string endpoint;
    string healthTool;
|};

final DeploymentInfo[] & readonly DEPLOYMENTS = [
    {name: "wso2am", product: "apim", 'version: "4.2.0", environment: "demo", endpoint: "http://apim-mcp:8402", healthTool: "apim_health"},
    {name: "wso2mi", product: "mi", 'version: "4.2.0", environment: "demo", endpoint: "http://mi-mcp:8403", healthTool: "mi_health"},
    {name: "wso2is", product: "is", 'version: "6.1.0", environment: "demo", endpoint: "http://is-mcp:8404", healthTool: "is_health"},
    {name: "store-service", product: "mesh", 'version: "n/a", environment: "demo", endpoint: "http://store:9090", healthTool: ""},
    {name: "customer-service", product: "mesh", 'version: "n/a", environment: "demo", endpoint: "http://customer:9090", healthTool: ""},
    {name: "order-service", product: "mesh", 'version: "n/a", environment: "demo", endpoint: "http://order:9090", healthTool: ""},
    {name: "inventory-service", product: "mesh", 'version: "n/a", environment: "demo", endpoint: "http://inventory:9090", healthTool: ""},
    {name: "invoice-service", product: "mesh", 'version: "n/a", environment: "demo", endpoint: "http://invoice:9090", healthTool: ""},
    {name: "payment-service", product: "mesh", 'version: "n/a", environment: "demo", endpoint: "http://payment:9090", healthTool: ""},
    {name: "notification-service", product: "mesh", 'version: "n/a", environment: "demo", endpoint: "http://notification:9090", healthTool: ""}
];

isolated function listDeployments() returns DeploymentInfo[] => DEPLOYMENTS;

isolated function catalogLookup(string name) returns ServiceInfo? => SERVICE_CATALOG[name];

isolated function listAllServices() returns string[] {
    string[] names = [];
    foreach string n in SERVICE_CATALOG.keys() { names.push(n); }
    return names;
}

isolated function getDependencies(string name, string direction) returns string[] {
    ServiceInfo? svc = SERVICE_CATALOG[name];
    if svc is () { return []; }
    if direction == "downstream" {
        string[] deps = [];
        foreach string d in svc.dependencies { deps.push(d); }
        string[]? async = ASYNC_EDGES[name];
        if async is string[] { foreach string d in async { deps.push(d); } }
        return deps;
    }
    if direction == "upstream" {
        string[] up = [];
        foreach var [sn, si] in SERVICE_CATALOG.entries() {
            if sn == name { continue; }
            foreach string dep in si.dependencies {
                if dep == name { up.push(sn); break; }
            }
            string[]? async = ASYNC_EDGES[sn];
            if async is string[] {
                foreach string ad in async {
                    if ad == name {
                        boolean found = false;
                        foreach string u in up { if u == sn { found = true; break; } }
                        if !found { up.push(sn); }
                        break;
                    }
                }
            }
        }
        return up;
    }
    // "both"
    string[] down = getDependencies(name, "downstream");
    string[] up2 = getDependencies(name, "upstream");
    string[] both = [];
    foreach string d in down { both.push(d); }
    foreach string u in up2 { both.push(u); }
    return both;
}
