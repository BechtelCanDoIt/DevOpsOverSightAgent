import ballerina/test;

@test:Config {}
function testDefaultModeIsMock() {
    test:assertEquals(currentMode(), "mock", "default MODE must be mock (creds-free demo)");
}

@test:Config {}
function testApimHealthIncludesMode() returns error? {
    json result = check callApimTool("apim_health", {});
    json modeField = check result.mode;
    test:assertEquals(modeField, "mock");
    json statusField = check result.status;
    test:assertEquals(statusField, "UP");
}

@test:Config {}
function testListApisReturnsThree() returns error? {
    json result = check callApimTool("apim_list_apis", {});
    json[] apis = <json[]>result;
    test:assertEquals(apis.length(), 3);
}

@test:Config {}
function testListApisIncludesBlockedApi() returns error? {
    json result = check callApimTool("apim_list_apis", {});
    json[] apis = <json[]>result;
    boolean foundBlocked = false;
    foreach json a in apis {
        json status = check a.lifeCycleStatus;
        if status == "BLOCKED" {
            foundBlocked = true;
        }
    }
    test:assertTrue(foundBlocked, "fixtures must include one BLOCKED API (feeds phase-7 top_issues)");
}

@test:Config {}
function testGetApiByName() returns error? {
    json result = check callApimTool("apim_get_api", {name: "PaymentAPI"});
    json name = check result.name;
    test:assertEquals(name, "PaymentAPI");
}

@test:Config {}
function testGetApiUnknownErrors() {
    json|error result = callApimTool("apim_get_api", {name: "NoSuchApi"});
    test:assertTrue(result is error, "unknown API must return an error");
}

@test:Config {}
function testListApplications() returns error? {
    json result = check callApimTool("apim_list_applications", {});
    json[] apps = <json[]>result;
    test:assertTrue(apps.length() > 0);
}

@test:Config {}
function testListSubscriptions() returns error? {
    json result = check callApimTool("apim_list_subscriptions", {});
    json[] subs = <json[]>result;
    test:assertTrue(subs.length() > 0);
}

@test:Config {}
function testGatewayStatus() returns error? {
    json result = check callApimTool("apim_gateway_status", {});
    json mode = check result.mode;
    test:assertEquals(mode, "mock");
}

@test:Config {}
function testUnknownToolErrors() {
    json|error result = callApimTool("no_such_tool", {});
    test:assertTrue(result is error, "unknown tool name must return an error");
}

@test:Config {}
function testToolDefsCoverAllSix() {
    json[] defs = apimToolDefs();
    test:assertEquals(defs.length(), 6, "must expose exactly the 6 documented apim tools");
}
