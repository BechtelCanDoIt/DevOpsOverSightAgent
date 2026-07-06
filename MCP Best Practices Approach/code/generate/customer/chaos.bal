import ballerina/http;
import ballerina/lang.runtime;

import ballerina/random;
import ballerina/time;

type ChaosState record {|
    int latencyMs = 0;
    int latencyUntil = 0;   // epoch seconds; window end (0 = off)
    float errorRate = 0.0;
    int errorUntil = 0;
    int errorStatus = 502;
|};

isolated ChaosState chaos = {};

final string chaosToken = envOr("CHAOS_TOKEN", "dev-chaos-token");

type LatencyReq record {| int ms; int duration_s = 60; |};
type ErrorReq record {| float rate; int status = 502; int duration_s = 60; |};

isolated function chaosAuthed(string? token) returns boolean => token == chaosToken;

// Call at the top of each business handler. Applies injected latency and, if an
// error is currently injected, returns the HTTP status to fail with (else ()).
isolated function applyChaos() returns int? {
    int now = time:utcNow()[0];
    int lat;
    int latUntil;
    float rate;
    int errUntil;
    int status;
    lock {
        lat = chaos.latencyMs;
        latUntil = chaos.latencyUntil;
        rate = chaos.errorRate;
        errUntil = chaos.errorUntil;
        status = chaos.errorStatus;
    }
    if latUntil > now && lat > 0 {
        runtime:sleep(<decimal>lat / 1000);
    }
    if errUntil > now && rate > 0.0 && random:createDecimal() < rate {
        return status;
    }
    return ();
}

isolated function chaosErrorResponse(int status) returns http:Response {
    http:Response r = new;
    r.statusCode = status;
    r.setPayload({'error: "chaos-injected", status: status});
    return r;
}

service /chaos on new http:Listener(9099) {
    isolated resource function post latency(@http:Header {name: "X-Chaos-Token"} string? token, @http:Payload LatencyReq req)
            returns json|http:Forbidden {
        if !chaosAuthed(token) {
            return http:FORBIDDEN;
        }
        int now = time:utcNow()[0];
        lock {
            chaos.latencyMs = req.ms;
            chaos.latencyUntil = now + req.duration_s;
        }
        return {status: "latency injected", ms: req.ms, duration_s: req.duration_s};
    }

    isolated resource function post 'error(@http:Header {name: "X-Chaos-Token"} string? token, @http:Payload ErrorReq req)
            returns json|http:Forbidden {
        if !chaosAuthed(token) {
            return http:FORBIDDEN;
        }
        int now = time:utcNow()[0];
        lock {
            chaos.errorRate = req.rate;
            chaos.errorStatus = req.status;
            chaos.errorUntil = now + req.duration_s;
        }
        return {status: "error injected", rate: req.rate, errorStatus: req.status};
    }

    isolated resource function post reset(@http:Header {name: "X-Chaos-Token"} string? token) returns json|http:Forbidden {
        if !chaosAuthed(token) {
            return http:FORBIDDEN;
        }
        lock {
            chaos.latencyMs = 0;
            chaos.latencyUntil = 0;
            chaos.errorRate = 0.0;
            chaos.errorUntil = 0;
        }
        return {status: "reset"};
    }
}
