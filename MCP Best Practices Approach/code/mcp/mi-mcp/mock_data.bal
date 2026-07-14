// Mock fixtures for WSO2 Micro Integrator 4.2's Management API surface.
// One message processor is deliberately left INACTIVE with a nonzero queue
// depth — a real stuck-queue anomaly for the phase-7 top_issues skill to
// surface without needing a live MI instance.

type ProxyServiceInfo record {|
    string name;
    string stats;
    boolean isRunning;
|};

final ProxyServiceInfo[] & readonly MOCK_PROXY_SERVICES = [
    {name: "OrderProxy", stats: "enabled", isRunning: true},
    {name: "PaymentProxy", stats: "enabled", isRunning: true}
];

type IntegrationApiInfo record {|
    string name;
    string 'context;
|};

final IntegrationApiInfo[] & readonly MOCK_APIS = [
    {name: "OrderIntegrationAPI", 'context: "/order-integration"}
];

type EndpointInfo record {|
    string name;
    boolean isActive;
|};

final EndpointInfo[] & readonly MOCK_ENDPOINTS = [
    {name: "PaymentBackendEP", isActive: true},
    {name: "LegacyBankEP", isActive: true}
];

type MessageProcessorInfo record {|
    string name;
    string state; // "ACTIVE" | "INACTIVE" (Ballerina 'DEACTIVATED' semantics)
    int messageCount;
|};

final MessageProcessorInfo[] & readonly MOCK_MESSAGE_PROCESSORS = [
    {name: "order-retry-processor", state: "INACTIVE", messageCount: 47},
    {name: "notification-dispatch-processor", state: "ACTIVE", messageCount: 0}
];

final string[] & readonly MOCK_LOGS = [
    "2026-07-10 09:00:01,000 INFO {OrderProxy} - Proxy started",
    "2026-07-10 09:15:22,441 WARN {order-retry-processor} - Message processor deactivated after 3 consecutive failures",
    "2026-07-10 09:15:23,000 INFO {order-retry-processor} - 47 messages queued for retry"
];

function callMiMock(string name, json arguments) returns json|error {
    if name == "mi_health" {
        return {status: "UP", mode: "mock"};
    }
    if name == "mi_list_proxy_services" {
        return MOCK_PROXY_SERVICES.toJson();
    }
    if name == "mi_list_apis" {
        return MOCK_APIS.toJson();
    }
    if name == "mi_list_endpoints" {
        return MOCK_ENDPOINTS.toJson();
    }
    if name == "mi_get_message_processors" {
        return MOCK_MESSAGE_PROCESSORS.toJson();
    }
    if name == "mi_get_logs" {
        return {lines: MOCK_LOGS};
    }
    return error(string `Unknown MI tool: ${name}`);
}
