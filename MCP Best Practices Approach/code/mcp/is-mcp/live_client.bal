// Live-mode implementation — calls a real WSO2 Identity Server 6.1 instance
// instead of the mock fixtures in mock_data.bal. Only exercised when
// MODE=live; kept isolated so a live-mode issue can never affect the default
// mock-mode demo path.
//
// NOT verified against a real IS 6.1 instance in this session — treat as a
// documented best-effort starting point per the product's REST API docs and
// verify against your actual instance before relying on it.

import ballerina/http;

configurable string isBaseUrl = "https://wso2is:9443";

function isBase() returns string => envOrCfg("IS_BASE_URL", isBaseUrl);
function isUsername() returns string => envOr("IS_USERNAME", "admin");
function isPassword() returns string => envOr("IS_PASSWORD", "admin");

// The Carbon health-check API is unauthenticated by default (since IS 5.7.0).
function isHealthLive() returns json|error {
    http:Client hc = check new (isBase(), timeout = 10, secureSocket = {enable: false});
    http:Response|error r = hc->get("/api/health-check/v1.0/health");
    if r is error {
        return {status: "DOWN", mode: "live", 'error: r.message()};
    }
    return {status: r.statusCode == 200 ? "UP" : "DEGRADED", mode: "live", httpStatus: r.statusCode};
}

function isAuthedClient() returns http:Client|error {
    return new (isBase(), timeout = 10, secureSocket = {enable: false},
        auth = {username: isUsername(), password: isPassword()});
}

function callIsLive(string name, json arguments) returns json|error {
    if name == "is_health" {
        return isHealthLive();
    }
    http:Client c = check isAuthedClient();
    if name == "is_server_info" {
        http:Response resp = check c->get("/api/server/v1/configs");
        json body = check resp.getJsonPayload();
        return {'version: "unknown", raw: body, mode: "live"};
    }
    if name == "is_list_applications" {
        http:Response resp = check c->get("/api/server/v1/applications");
        json body = check resp.getJsonPayload();
        return check body.applications;
    }
    if name == "is_user_store_status" {
        http:Response resp = check c->get("/api/server/v1/userstores");
        return check resp.getJsonPayload();
    }
    if name == "is_count_users" {
        http:Response resp = check c->get("/scim2/Users?count=0");
        json body = check resp.getJsonPayload();
        json total = check body.totalResults;
        return {totalResults: total, mode: "live"};
    }
    return error(string `Unknown IS tool: ${name}`);
}
