import ballerina/test;

@test:Config {}
function testDefaultModeIsMock() {
    test:assertEquals(currentMode(), "mock", "default MODE must be mock (creds-free demo)");
}

@test:Config {}
function testMiHealthIncludesMode() returns error? {
    json result = check callMiTool("mi_health", {});
    json modeField = check result.mode;
    test:assertEquals(modeField, "mock");
}

@test:Config {}
function testListProxyServices() returns error? {
    json result = check callMiTool("mi_list_proxy_services", {});
    json[] svcs = <json[]>result;
    test:assertTrue(svcs.length() > 0);
}

@test:Config {}
function testListApis() returns error? {
    json result = check callMiTool("mi_list_apis", {});
    json[] apis = <json[]>result;
    test:assertTrue(apis.length() > 0);
}

@test:Config {}
function testListEndpoints() returns error? {
    json result = check callMiTool("mi_list_endpoints", {});
    json[] eps = <json[]>result;
    test:assertTrue(eps.length() > 0);
}

@test:Config {}
function testMessageProcessorsIncludesInactiveOne() returns error? {
    json result = check callMiTool("mi_get_message_processors", {});
    json[] procs = <json[]>result;
    boolean foundInactive = false;
    foreach json p in procs {
        json state = check p.state;
        json count = check p.messageCount;
        if state == "INACTIVE" && count is int && count > 0 {
            foundInactive = true;
        }
    }
    test:assertTrue(foundInactive, "fixtures must include an INACTIVE processor with a nonzero queue (feeds phase-7 top_issues)");
}

@test:Config {}
function testGetLogsReturnsLines() returns error? {
    json result = check callMiTool("mi_get_logs", {});
    json lines = check result.lines;
    json[] linesArr = <json[]>lines;
    test:assertTrue(linesArr.length() > 0);
}

@test:Config {}
function testUnknownToolErrors() {
    json|error result = callMiTool("no_such_tool", {});
    test:assertTrue(result is error, "unknown tool name must return an error");
}

@test:Config {}
function testToolDefsCoverAllSix() {
    json[] defs = miToolDefs();
    test:assertEquals(defs.length(), 6, "must expose exactly the 6 documented mi tools");
}
