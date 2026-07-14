// The ONLY code path allowed to invoke a backend tool that the write guardrail
// (federation.bal isToolAllowed) filtered out of the discoverable registry.
// Runbooks (runbooks.bal) call this directly to perform real remediation
// actions (e.g. a docker/k8s restart) — the agent itself can never reach a
// filtered tool, since routeToolCall only ever calls registered tools.
//
// "Reads federate through discover_tools + routeToolCall; writes only run via
// topology__run_runbook." — see Refactor R4.2 in todo/phase-3-mcp.md.

import ballerina/http;

function callBackendToolDirect(string label, string realName, json args) returns string|error {
    http:Client? c = getBackend(label);
    if c is () {
        return error(string `${label} backend not connected`);
    }
    McpToolResult result = check mcpCallTool(c, realName, args, 98);
    if result.isError {
        return error(result.text);
    }
    return result.text;
}
