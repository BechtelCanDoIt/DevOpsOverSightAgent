import ballerina/test;

@test:Config {}
function testDefaultModeIsMock() {
    test:assertEquals(currentMode(), "mock", "default MODE must be mock (creds-free demo)");
}

@test:Config {}
function testIsHealthIncludesMode() returns error? {
    json result = check callIsTool("is_health", {});
    json modeField = check result.mode;
    test:assertEquals(modeField, "mock");
}

@test:Config {}
function testServerInfoIncludesVersion() returns error? {
    json result = check callIsTool("is_server_info", {});
    json v = check result.'version;
    test:assertEquals(v, "6.1.0");
}

@test:Config {}
function testListApplications() returns error? {
    json result = check callIsTool("is_list_applications", {});
    json[] apps = <json[]>result;
    test:assertEquals(apps.length(), 2);
}

@test:Config {}
function testUserStoreStatusIncludesDisconnected() returns error? {
    json result = check callIsTool("is_user_store_status", {});
    json[] stores = <json[]>result;
    boolean foundDisconnected = false;
    foreach json s in stores {
        json status = check s.status;
        if status == "Disconnected" {
            foundDisconnected = true;
        }
    }
    test:assertTrue(foundDisconnected, "fixtures must include a Disconnected user store (feeds phase-7 top_issues)");
}

@test:Config {}
function testCountUsers() returns error? {
    json result = check callIsTool("is_count_users", {});
    json total = check result.totalResults;
    test:assertEquals(total, 42);
}

@test:Config {}
function testUnknownToolErrors() {
    json|error result = callIsTool("no_such_tool", {});
    test:assertTrue(result is error, "unknown tool name must return an error");
}

@test:Config {}
function testToolDefsCoverAllFive() {
    json[] defs = isToolDefs();
    test:assertEquals(defs.length(), 5, "must expose exactly the 5 documented is tools");
}
