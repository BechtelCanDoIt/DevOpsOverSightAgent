// Mock fixtures for WSO2 API Manager 4.2's Publisher/Admin REST surface.
// One API is deliberately left BLOCKED so the phase-7 top_issues skill has a
// real cross-product anomaly to surface without needing a live APIM.

type ApiInfo record {|
    string id;
    string name;
    string 'version;
    string context;
    string lifeCycleStatus;
    string 'type;
|};

final ApiInfo[] & readonly MOCK_APIS = [
    {id: "api-001", name: "PaymentAPI", 'version: "1.0.0", context: "/payment", lifeCycleStatus: "PUBLISHED", 'type: "HTTP"},
    {id: "api-002", name: "OrderAPI", 'version: "1.0.0", context: "/order", lifeCycleStatus: "PUBLISHED", 'type: "HTTP"},
    {id: "api-003", name: "LegacyBillingAPI", 'version: "0.9.0", context: "/legacy-billing", lifeCycleStatus: "BLOCKED", 'type: "HTTP"}
];

type ApplicationInfo record {|
    string applicationId;
    string name;
    string throttlingPolicy;
    string status;
|};

final ApplicationInfo[] & readonly MOCK_APPLICATIONS = [
    {applicationId: "app-001", name: "DefaultApplication", throttlingPolicy: "Unlimited", status: "APPROVED"},
    {applicationId: "app-002", name: "PaymentApp", throttlingPolicy: "Gold", status: "APPROVED"}
];

type SubscriptionInfo record {|
    string subscriptionId;
    string applicationId;
    string apiId;
    string throttlingPolicy;
    string status;
|};

final SubscriptionInfo[] & readonly MOCK_SUBSCRIPTIONS = [
    {subscriptionId: "sub-001", applicationId: "app-002", apiId: "api-001", throttlingPolicy: "Gold", status: "UNBLOCKED"},
    {subscriptionId: "sub-002", applicationId: "app-001", apiId: "api-002", throttlingPolicy: "Unlimited", status: "UNBLOCKED"}
];

type GatewayEnvironment record {|
    string name;
    string 'type;
    string status;
|};

final GatewayEnvironment[] & readonly MOCK_GATEWAYS = [
    {name: "Default", 'type: "hybrid", status: "UP"},
    {name: "Production", 'type: "hybrid", status: "UP"}
];

function callApimMock(string name, json arguments) returns json|error {
    if name == "apim_health" {
        return {status: "UP", mode: "mock", 'version: "4.2.0"};
    }
    if name == "apim_list_apis" {
        return MOCK_APIS.toJson();
    }
    if name == "apim_get_api" {
        map<json> argsMap = <map<json>>arguments;
        string idField = (argsMap["id"] ?: "").toString();
        string nameField = (argsMap["name"] ?: "").toString();
        foreach ApiInfo a in MOCK_APIS {
            if a.id == idField || a.name == nameField {
                return a.toJson();
            }
        }
        return error(string `API not found: ${idField == "" ? nameField : idField}`);
    }
    if name == "apim_list_applications" {
        return MOCK_APPLICATIONS.toJson();
    }
    if name == "apim_list_subscriptions" {
        return MOCK_SUBSCRIPTIONS.toJson();
    }
    if name == "apim_gateway_status" {
        return {mode: "mock", environments: MOCK_GATEWAYS.toJson()};
    }
    return error(string `Unknown APIM tool: ${name}`);
}
