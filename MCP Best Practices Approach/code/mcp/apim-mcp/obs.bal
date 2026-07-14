import ballerina/os;

isolated function envOr(string name, string fallback) returns string {
    string v = os:getEnv(name);
    return v == "" ? fallback : v;
}

// env var wins over the Ballerina configurable default (mirrors mcp-proxy).
isolated function envOrCfg(string envKey, string cfgDefault) returns string {
    string v = os:getEnv(envKey);
    return v == "" ? cfgDefault : v;
}
