import ballerina/time;

// Hard, code-level human-approval gate for topology__run_runbook — mirrors
// the LangChain sibling's HumanInTheLoopMiddleware + InMemorySaver interrupt
// (LangChain Approach/code/agent/devops_oversight_agent/.../agent.py: the
// graph physically interrupts before the tool executes). Ballerina has no
// graph/checkpointer runtime, so the same guarantee is built by hand:
//
//   - The agent's tool dispatcher (devops_oversight_agent.bal makeDispatcher)
//     NEVER forwards topology__run_runbook to the proxy. Every attempt is
//     intercepted here, stored, and answered with a sentinel.
//   - The LLM tool-use loops (anthropic_client.bal, llm_client.bal) treat
//     that sentinel as a hard stop — they end the turn loop immediately
//     instead of burning further turns or letting the model narrate a
//     result that never happened.
//   - The ONLY code path that can execute a runbook for real is
//     approveRunbook() in devops_oversight_agent.bal, reached exclusively
//     via a separate "approve <token>" chat message parsed BEFORE the
//     message ever reaches the LLM.
//
// A non-compliant or adversarial model cannot force execution no matter what
// it claims or how many times it retries — it can only ever reach
// interceptRunRunbook, never the proxy's real run_runbook dispatch.

// Prefix the loops check immediately after every dispatcher call. Seeing it
// means: stop the turn loop right here and hand the pending-approval text
// back to the caller instead of continuing.
const string RUNBOOK_HALT_MARKER = "@@RUNBOOK_APPROVAL_REQUIRED@@";

type PendingRunbook record {|
    string token;
    string runbookId;
    json params;
    string proposedAt;
|};

isolated map<PendingRunbook> pendingRunbooks = {};
isolated int approvalTokenCounter = 0;

isolated function nextApprovalToken() returns string {
    lock {
        approvalTokenCounter += 1;
        return string `RB-${approvalTokenCounter}`;
    }
}

isolated function storePendingRunbook(string token, string runbookId, json params) {
    lock {
        pendingRunbooks[token] = {token: token, runbookId: runbookId, params: params.clone(), proposedAt: time:utcToString(time:utcNow())};
    }
}

// Atomically removes and returns the pending entry — a token can only ever
// be consumed once, so a repeated "approve <token>" after the first success
// correctly reports "not found" rather than executing twice.
isolated function takePendingRunbook(string token) returns PendingRunbook? {
    lock {
        PendingRunbook? p = pendingRunbooks[token];
        if p is PendingRunbook {
            _ = pendingRunbooks.remove(token);
            return p.clone();
        }
        return ();
    }
}

isolated function pendingRunbookCount() returns int {
    lock {
        return pendingRunbooks.length();
    }
}

// Called by the dispatcher instead of ever forwarding topology__run_runbook
// to the proxy. Returns [token, sentinelText] — the dispatcher hands the
// sentinel (RUNBOOK_HALT_MARKER-prefixed) back to the LLM as the tool
// result; the token is exposed separately so this is directly unit-testable
// without string-parsing prose.
function interceptRunRunbook(json args) returns [string, string] {
    string runbookId = "";
    json params = {};
    if args is map<json> {
        json? idField = args["id"];
        if idField is string {
            runbookId = idField;
        }
        json? paramsField = args["params"];
        if paramsField !is () {
            params = paramsField;
        }
    }
    string token = nextApprovalToken();
    storePendingRunbook(token, runbookId, params);
    string sentinel = RUNBOOK_HALT_MARKER +
        string `EXECUTION BLOCKED — human approval required before running "${runbookId}" with params ${params.toJsonString()}. ` +
        string `This action has NOT run. Approval token: ${token}. ` +
        "Reply with \"approve " + token + "\" to execute it, or \"deny " + token + "\" to cancel. " +
        "Report this to the operator and stop — do not claim the action succeeded.";
    return [token, sentinel];
}

// Parses a chat message as an approval/denial command. Checked in chat()
// BEFORE the message ever reaches the LLM or the skill-command parser.
isolated function parseApprovalCommand(string message) returns [string, string]? {
    string trimmed = message.trim();
    string lower = trimmed.toLowerAscii();
    if lower.startsWith("approve ") {
        return ["approve", trimmed.substring(8).trim()];
    }
    if lower.startsWith("deny ") {
        return ["deny", trimmed.substring(5).trim()];
    }
    return ();
}
