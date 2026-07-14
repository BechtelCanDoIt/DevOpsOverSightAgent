// Live-mode implementation — calls a real WSO2 API Manager 4.2 instance
// instead of the mock fixtures in mock_data.bal. Only exercised when
// MODE=live; kept in its own file so a live-mode issue can never affect the
// default mock-mode demo path.
//
// NOTE: this is the most failure-prone live path of the three new WSO2
// wrappers (dynamic client registration + password grant + scopes vary by
// deployment). It has NOT been verified against a real APIM 4.2 instance in
// this session — treat as a documented best-effort starting point and verify
// scopes/endpoints against your actual instance before relying on it.

import ballerina/http;
import ballerina/log;

configurable string apimBaseUrl = "https://wso2am:9443";

isolated string cachedAccessToken = "";

isolated function getCachedToken() returns string {
    lock {
        return cachedAccessToken;
    }
}

isolated function setCachedToken(string token) {
    lock {
        cachedAccessToken = token;
    }
}

function apimBase() returns string => envOrCfg("APIM_BASE_URL", apimBaseUrl);
function apimUsername() returns string => envOr("APIM_USERNAME", "admin");
function apimPassword() returns string => envOr("APIM_PASSWORD", "admin");

// Health uses the unauthenticated /services/Version endpoint — no token needed.
function apimHealthLive() returns json|error {
    http:Client hc = check new (apimBase(), timeout = 10, secureSocket = {enable: false});
    http:Response|error r = hc->get("/services/Version");
    if r is error {
        return {status: "DOWN", mode: "live", 'error: r.message()};
    }
    return {status: r.statusCode == 200 ? "UP" : "DEGRADED", mode: "live", httpStatus: r.statusCode};
}

// Dynamic Client Registration (WSO2 APIM's /client-registration endpoint) +
// OAuth2 password grant, result cached for the life of the process.
function ensureAccessToken() returns string|error {
    string existing = getCachedToken();
    if existing != "" {
        return existing;
    }
    http:Client dcrClient = check new (apimBase(), timeout = 10, secureSocket = {enable: false},
        auth = {username: apimUsername(), password: apimPassword()});
    json dcrPayload = {
        clientName: "devops-oversight-apim-mcp",
        owner: apimUsername(),
        grantType: "password refresh_token",
        saasApp: true
    };
    http:Response|error dcrResp = dcrClient->post("/client-registration/v0.17/register", dcrPayload);
    if dcrResp is error {
        return error(string `APIM client registration failed: ${dcrResp.message()}`);
    }
    if dcrResp.statusCode >= 300 {
        return error(string `APIM DCR returned HTTP ${dcrResp.statusCode}: ${(check dcrResp.getTextPayload())}`);
    }
    json dcrBody = check dcrResp.getJsonPayload();
    string clientId = (check dcrBody.clientId).toString();
    string clientSecret = (check dcrBody.clientSecret).toString();

    // Build the form body explicitly (a raw string with an urlencoded content
    // type). WSO2's /oauth2/token tolerates the raw spaces in the scope list,
    // matching a working `curl -d`. Passing a map<string> here serialized
    // wrong and produced an empty/failed token response.
    http:Client tokenClient = check new (apimBase(), timeout = 10, secureSocket = {enable: false},
        auth = {username: clientId, password: clientSecret});
    // Scopes span all three portals: publisher (api_view), devportal
    // (app_view/app_manage/subscribe — the devportal returns 401, not 403,
    // without these), and admin. Verified against APIM 4.2.0.
    string formBody = string `grant_type=password&username=${apimUsername()}&password=${apimPassword()}` +
        "&scope=apim:api_view apim:app_view apim:app_manage apim:subscribe apim:admin";
    http:Request tokenReq = new;
    tokenReq.setTextPayload(formBody, "application/x-www-form-urlencoded");
    http:Response|error tokenResp = tokenClient->post("/oauth2/token", tokenReq);
    if tokenResp is error {
        return error(string `APIM token request failed: ${tokenResp.message()}`);
    }
    if tokenResp.statusCode >= 300 {
        return error(string `APIM token returned HTTP ${tokenResp.statusCode}: ${(check tokenResp.getTextPayload())}`);
    }
    json tokenBody = check tokenResp.getJsonPayload();
    string accessToken = (check tokenBody.access_token).toString();
    setCachedToken(accessToken);
    log:printInfo("apim-mcp: obtained live access token");
    return accessToken;
}

// Helper: GET a paginated publisher/devportal/admin resource and return its
// `list`. Surfaces the HTTP status + body on failure instead of a cryptic
// KeyNotFound when the response isn't the expected {count,list,pagination}.
function apimGetList(http:Client c, string path) returns json|error {
    http:Response resp = check c->get(path);
    if resp.statusCode >= 300 {
        return error(string `APIM GET ${path} -> HTTP ${resp.statusCode}: ${(check resp.getTextPayload())}`);
    }
    json body = check resp.getJsonPayload();
    return check body.list;
}

function apimAuthedClient() returns http:Client|error {
    string token = check ensureAccessToken();
    return new (apimBase(), timeout = 10, secureSocket = {enable: false},
        auth = {token: token});
}

function callApimLive(string name, json arguments) returns json|error {
    if name == "apim_health" {
        return apimHealthLive();
    }
    http:Client c = check apimAuthedClient();
    if name == "apim_list_apis" {
        return apimGetList(c, "/api/am/publisher/v4/apis");
    }
    if name == "apim_get_api" {
        map<json> argsMap = <map<json>>arguments;
        string apiId = (argsMap["id"] ?: "").toString();
        if apiId == "" {
            return error("apim_get_api (live mode) requires 'id' (the APIM-assigned API UUID)");
        }
        http:Response resp = check c->get(string `/api/am/publisher/v4/apis/${apiId}`);
        return check resp.getJsonPayload();
    }
    if name == "apim_list_applications" {
        return apimGetList(c, "/api/am/devportal/v3/applications");
    }
    if name == "apim_list_subscriptions" {
        // The devportal subscriptions API rejects an unscoped list (HTTP 400 —
        // needs applicationId or apiId). Honor an optional applicationId arg;
        // otherwise aggregate each application's subscriptions.
        map<json> argsMap = arguments is map<json> ? <map<json>>arguments : {};
        string appId = (argsMap["applicationId"] ?: "").toString();
        if appId != "" {
            return apimGetList(c, string `/api/am/devportal/v3/subscriptions?applicationId=${appId}`);
        }
        json apps = check apimGetList(c, "/api/am/devportal/v3/applications");
        json[] allSubs = [];
        if apps is json[] {
            foreach json app in apps {
                string id = (check app.applicationId).toString();
                json subs = check apimGetList(c, string `/api/am/devportal/v3/subscriptions?applicationId=${id}`);
                if subs is json[] {
                    allSubs.push(...subs);
                }
            }
        }
        return allSubs;
    }
    if name == "apim_gateway_status" {
        return {mode: "live", environments: check apimGetList(c, "/api/am/admin/v4/environments")};
    }
    return error(string `Unknown APIM tool: ${name}`);
}
