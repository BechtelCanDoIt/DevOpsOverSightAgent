import ballerina/os;

isolated function envOr(string name, string fallback) returns string {
    string v = os:getEnv(name);
    return v == "" ? fallback : v;
}

// env var wins over the Ballerina configurable default (mirrors agent pattern).
isolated function envOrCfg(string envKey, string cfgDefault) returns string {
    string v = os:getEnv(envKey);
    return v == "" ? cfgDefault : v;
}

// Accepts Y/yes/true/1 (true) and N/no/false/0 (false), case-insensitive.
// Anything else falls back. Y/N is the form used by the INCLUDE_* toggles.
isolated function envOrBool(string name, boolean fallback) returns boolean {
    string v = os:getEnv(name).toLowerAscii().trim();
    if v == "" {
        return fallback;
    }
    if v == "y" || v == "yes" || v == "true" || v == "1" {
        return true;
    }
    if v == "n" || v == "no" || v == "false" || v == "0" {
        return false;
    }
    return fallback;
}
