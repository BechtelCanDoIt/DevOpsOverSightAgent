// Live-mode implementation — calls a real WSO2 Micro Integrator 4.2
// Management API (port 9164) instead of the mock fixtures in mock_data.bal.
// Only exercised when MODE=live; kept isolated so a live-mode issue can never
// affect the default mock-mode demo path.
//
// NOT verified against a real MI 4.2 instance in this session — treat as a
// documented best-effort starting point per the product's Management API
// docs and verify against your actual instance before relying on it.

import ballerina/http;
import ballerina/log;

configurable string miBaseUrl = "https://wso2mi:9164";

isolated string cachedAccessToken = "";

isolated function getCachedMiToken() returns string {
    lock {
        return cachedAccessToken;
    }
}

isolated function setCachedMiToken(string token) {
    lock {
        cachedAccessToken = token;
    }
}

function miBase() returns string => envOrCfg("MI_BASE_URL", miBaseUrl);
function miUsername() returns string => envOr("MI_USERNAME", "admin");
function miPassword() returns string => envOr("MI_PASSWORD", "admin");

// The Management API root answers 401 unauthenticated — a response of any kind
// means MI is up. (There is no unauthenticated /healthz on MI 4.3.)
function miHealthLive() returns json|error {
    http:Client hc = check new (miBase(), timeout = 10, secureSocket = {enable: false});
    http:Response|error r = hc->get("/management/");
    if r is error {
        return {status: "DOWN", mode: "live", 'error: r.message()};
    }
    boolean up = r.statusCode == 200 || r.statusCode == 401;
    return {status: up ? "UP" : "DEGRADED", mode: "live", httpStatus: r.statusCode};
}

function ensureMiToken() returns string|error {
    string existing = getCachedMiToken();
    if existing != "" {
        return existing;
    }
    // MI's Management API login is GET /management/login with HTTP Basic auth
    // (verified against MI 4.3.0) — it returns {"AccessToken": "..."}. It is NOT
    // a POST with a JSON body; that returns an empty response ("No content").
    http:Client loginClient = check new (miBase(), timeout = 10, secureSocket = {enable: false},
        auth = {username: miUsername(), password: miPassword()});
    http:Response|error resp = loginClient->get("/management/login");
    if resp is error {
        return error(string `MI management login failed: ${resp.message()}`);
    }
    json body = check resp.getJsonPayload();
    string token = (check body.AccessToken).toString();
    setCachedMiToken(token);
    log:printInfo("mi-mcp: obtained live management token");
    return token;
}

function miAuthedClient() returns http:Client|error {
    string token = check ensureMiToken();
    return new (miBase(), timeout = 10, secureSocket = {enable: false}, auth = {token: token});
}

function callMiLive(string name, json arguments) returns json|error {
    if name == "mi_health" {
        return miHealthLive();
    }
    http:Client c = check miAuthedClient();
    if name == "mi_list_proxy_services" {
        http:Response resp = check c->get("/management/proxy-services");
        json body = check resp.getJsonPayload();
        return check body.list;
    }
    if name == "mi_list_apis" {
        http:Response resp = check c->get("/management/apis");
        json body = check resp.getJsonPayload();
        return check body.list;
    }
    if name == "mi_list_endpoints" {
        http:Response resp = check c->get("/management/endpoints");
        json body = check resp.getJsonPayload();
        return check body.list;
    }
    if name == "mi_get_message_processors" {
        http:Response resp = check c->get("/management/message-processors");
        json body = check resp.getJsonPayload();
        return check body.list;
    }
    if name == "mi_get_logs" {
        http:Response resp = check c->get("/management/logs");
        return check resp.getJsonPayload();
    }
    return error(string `Unknown MI tool: ${name}`);
}
