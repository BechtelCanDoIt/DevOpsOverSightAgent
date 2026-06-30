import ballerina/os;

isolated function envOr(string name, string fallback) returns string {
    string v = os:getEnv(name);
    return v == "" ? fallback : v;
}
