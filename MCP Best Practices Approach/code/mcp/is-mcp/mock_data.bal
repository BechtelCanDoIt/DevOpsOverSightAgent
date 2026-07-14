// Mock fixtures for WSO2 Identity Server 6.1's Carbon health-check + server
// management + SCIM2 surface. The secondary user store is deliberately left
// Disconnected — a real anomaly for the phase-7 top_issues skill to surface
// without needing a live IS instance.

type ApplicationInfo record {|
    string id;
    string name;
    boolean isActive;
|};

final ApplicationInfo[] & readonly MOCK_APPLICATIONS = [
    {id: "app-001", name: "My Workspace App", isActive: true},
    {id: "app-002", name: "Admin Portal", isActive: true}
];

type UserStoreInfo record {|
    string name;
    string status; // "Active" | "Disconnected"
|};

final UserStoreInfo[] & readonly MOCK_USER_STORES = [
    {name: "PRIMARY", status: "Active"},
    {name: "SECONDARY", status: "Disconnected"}
];

final int MOCK_USER_COUNT = 42;

function callIsMock(string name, json arguments) returns json|error {
    if name == "is_health" {
        return {status: "UP", mode: "mock"};
    }
    if name == "is_server_info" {
        return {'version: "6.1.0", serverName: "wso2is", mode: "mock"};
    }
    if name == "is_list_applications" {
        return MOCK_APPLICATIONS.toJson();
    }
    if name == "is_user_store_status" {
        return MOCK_USER_STORES.toJson();
    }
    if name == "is_count_users" {
        return {totalResults: MOCK_USER_COUNT, mode: "mock"};
    }
    return error(string `Unknown IS tool: ${name}`);
}
