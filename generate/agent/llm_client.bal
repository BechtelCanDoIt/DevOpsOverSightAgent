// Pluggable LLM backend — select via LLM_PROVIDER env var:
//
//   anthropic (default) — Anthropic Messages API, called directly or via
//                         AMP's AI gateway (AMP injects ANTHROPIC_URL).
//                         Requires ANTHROPIC_API_KEY.
//   ollama              — Local Ollama /api/chat.
//                         Requires OLLAMA_BASE_URL (default: host.docker.internal:11434)
//                         and OLLAMA_MODEL (default: qwen3.5:9b). Creds-free.
//   openai              — OpenAI /v1/chat/completions (or any OpenAI-compatible
//                         endpoint via OPENAI_BASE_URL). Requires OPENAI_API_KEY.
//   amp                 — WSO2 Agent Manager AI gateway (OpenAI-compatible).
//                         AMP injects LLM_BASE_URL and optionally LLM_API_KEY.
//                         Set LLM_MODEL to control which model AMP routes to.
//
// All providers share AnthropicTool[] + dispatcher — devops_oversight_agent.bal
// is provider-agnostic.

import ballerina/http;
import ballerina/lang.value;
import ballerina/log;

// ── Provider router ───────────────────────────────────────────────────────────

function runConfiguredLlm(
    string systemPrompt,
    string userPrompt,
    AnthropicTool[] tools,
    function (string toolName, json args) returns string toolDispatcher,
    int maxTurns
) returns string|error {
    string provider = envOr("LLM_PROVIDER", "anthropic");

    if provider == "ollama" {
        string baseUrl = envOr("OLLAMA_BASE_URL", "http://host.docker.internal:11434");
        string model = envOr("OLLAMA_MODEL", "qwen3.5:9b");
        log:printInfo("LLM provider: ollama", model = model, baseUrl = baseUrl);
        return runOllamaLoop(baseUrl, model, systemPrompt, userPrompt, tools, toolDispatcher, maxTurns);
    }

    if provider == "openai" {
        string baseUrl = envOr("OPENAI_BASE_URL", "https://api.openai.com");
        string apiKey = envOr("OPENAI_API_KEY", "");
        if apiKey == "" {
            return error("OPENAI_API_KEY not set (LLM_PROVIDER=openai).");
        }
        string model = envOr("OPENAI_MODEL", "gpt-4o");
        log:printInfo("LLM provider: openai", model = model);
        return runOpenAICompatLoop(baseUrl, apiKey, model, systemPrompt, userPrompt, tools, toolDispatcher, maxTurns);
    }

    if provider == "amp" {
        // AMP injects LLM_BASE_URL for its AI gateway (OpenAI-compatible).
        // LLM_API_KEY is optional — AMP may handle auth at the gateway level.
        string baseUrl = envOr("LLM_BASE_URL", "");
        if baseUrl == "" {
            return error("LLM_BASE_URL not set (LLM_PROVIDER=amp). AMP must inject this env var.");
        }
        string apiKey = envOr("LLM_API_KEY", "");
        string model = envOr("LLM_MODEL", "gpt-4o");
        log:printInfo("LLM provider: amp", model = model, baseUrl = baseUrl);
        return runOpenAICompatLoop(baseUrl, apiKey, model, systemPrompt, userPrompt, tools, toolDispatcher, maxTurns);
    }

    // Default: Anthropic Claude.
    // AMP routes calls through its AI gateway by injecting ANTHROPIC_URL.
    string apiKey = envOr("ANTHROPIC_API_KEY", "");
    if apiKey == "" {
        return error("ANTHROPIC_API_KEY not set (LLM_PROVIDER=anthropic). Set a real sk-ant-api03 key or switch LLM_PROVIDER=ollama.");
    }
    string model = envOr("AGENT_MODEL", "claude-sonnet-4-6");
    log:printInfo("LLM provider: anthropic", model = model);
    return runAgentLoop(apiKey, model, systemPrompt, userPrompt, tools, toolDispatcher, maxTurns);
}

// ── Ollama loop (/api/chat) ───────────────────────────────────────────────────
// Uses Ollama's native chat format. Arguments arrive as JSON objects (not strings).
// Tool results use {role:"tool", tool_name:..., content:...}.

function runOllamaLoop(
    string baseUrl,
    string model,
    string systemPrompt,
    string userPrompt,
    AnthropicTool[] tools,
    function (string toolName, json args) returns string toolDispatcher,
    int maxTurns
) returns string|error {
    http:Client ollama = check new (baseUrl, timeout = 180);

    json[] messages = [
        {role: "system", content: systemPrompt},
        {role: "user", content: userPrompt}
    ];
    string finalText = "Investigation incomplete — max turns reached.";

    int turn = 0;
    while turn < maxTurns {
        turn += 1;

        // Rebuild tool list each turn — activeTools may grow via discover_tools.
        json[] ollamaTools = [];
        foreach AnthropicTool t in tools {
            ollamaTools.push({
                'type: "function",
                'function: {name: t.name, description: t.description, parameters: t.input_schema}
            });
        }

        json requestBody = {
            model: model,
            messages: messages,
            tools: ollamaTools,
            'stream: false,
            options: {num_ctx: 8192}
        };

        http:Response|error resp = ollama->post("/api/chat", requestBody);
        if resp is error {
            return error(string `Ollama API call failed: ${resp.message()}`);
        }
        json body = check resp.getJsonPayload();
        if resp.statusCode != 200 {
            return error(string `Ollama API error ${resp.statusCode}: ${body.toJsonString()}`);
        }

        json message = check body.message;
        messages.push(message);

        json|error toolCallsField = message.tool_calls;
        if toolCallsField is json[] && toolCallsField.length() > 0 {
            foreach json tc in toolCallsField {
                json fn = check tc.'function;
                string toolName = (check fn.name).toString();
                json args = check fn.arguments;
                log:printInfo("tool call", tool = toolName);
                string result = toolDispatcher(toolName, args);
                messages.push({role: "tool", tool_name: toolName, content: result});
            }
        } else {
            json|error contentField = message.content;
            if contentField is json {
                string c = contentField.toString();
                if c.trim().length() > 0 {
                    finalText = c;
                }
            }
            break;
        }
    }
    return finalText;
}

// ── LLM readiness checks ─────────────────────────────────────────────────────
// Called at test suite setup (@test:BeforeSuite) and agent module init.
// For ollama: verifies the daemon is running and the model is installed,
// pulling it automatically if missing. For API-key providers: validates the
// required env vars are set.

function checkLlmReady() returns error? {
    string provider = envOr("LLM_PROVIDER", "anthropic");
    if provider == "ollama" {
        string baseUrl = envOr("OLLAMA_BASE_URL", "http://host.docker.internal:11434");
        string model = envOr("OLLAMA_MODEL", "qwen3.5:9b");
        return check checkOllamaReady(baseUrl, model);
    }
    if provider == "anthropic" {
        if envOr("ANTHROPIC_API_KEY", "") == "" {
            return error("ANTHROPIC_API_KEY is not set (LLM_PROVIDER=anthropic).");
        }
        return;
    }
    if provider == "openai" {
        if envOr("OPENAI_API_KEY", "") == "" {
            return error("OPENAI_API_KEY is not set (LLM_PROVIDER=openai).");
        }
        return;
    }
    if provider == "amp" {
        if envOr("LLM_BASE_URL", "") == "" {
            return error("LLM_BASE_URL is not set (LLM_PROVIDER=amp). AMP must inject this env var.");
        }
        return;
    }
    return error(string `Unknown LLM_PROVIDER '${provider}'. Valid values: anthropic, ollama, openai, amp.`);
}

function checkOllamaReady(string baseUrl, string model) returns error? {
    log:printInfo("checking Ollama", baseUrl = baseUrl, model = model);
    http:Client ollama = check new (baseUrl, timeout = 10);

    // 1 — Is the daemon reachable?
    http:Response|error tagsResp = ollama->get("/api/tags");
    if tagsResp is error {
        return error(string `Ollama daemon not reachable at ${baseUrl}: ${tagsResp.message()}. ` +
            "Install from https://ollama.com and run 'ollama serve' (or open the Ollama app on macOS).");
    }
    if tagsResp.statusCode != 200 {
        return error(string `Ollama at ${baseUrl} returned HTTP ${tagsResp.statusCode}. Ensure the daemon is running.`);
    }

    // 2 — Is the model installed?
    json body = check tagsResp.getJsonPayload();
    boolean modelFound = false;
    json|error modelsField = body.models;
    if modelsField is json[] {
        foreach json m in modelsField {
            json|error nameField = m.name;
            if nameField is string && (nameField == model || nameField.startsWith(model)) {
                modelFound = true;
                break;
            }
        }
    }

    if modelFound {
        log:printInfo("Ollama ready", model = model);
        return;
    }

    // 3 — Model missing: attempt auto-pull.
    log:printInfo(string `Model '${model}' not found locally — pulling (this may take several minutes)...`);
    http:Client puller = check new (baseUrl, timeout = 600);
    http:Response|error pullResp = puller->post("/api/pull", {name: model, 'stream: false});
    if pullResp is error {
        return error(string `Model '${model}' not installed and auto-pull failed: ${pullResp.message()}. ` +
            string `Run manually: ollama pull ${model}`);
    }
    if pullResp.statusCode != 200 {
        json|error pullBody = pullResp.getJsonPayload();
        string detail = pullBody is json ? pullBody.toJsonString() : "";
        string suffix = detail != "" ? string `: ${detail}` : "";
        return error(string `Model '${model}' pull returned HTTP ${pullResp.statusCode}${suffix}. ` +
            string `Run manually: ollama pull ${model}`);
    }
    log:printInfo(string `Model '${model}' pulled successfully.`);
}

// ── OpenAI-compatible loop (/v1/chat/completions) ─────────────────────────────
// Handles direct OpenAI and the WSO2 AMP AI gateway (both speak OpenAI format).
// Arguments arrive as JSON strings and must be parsed; tool results use tool_call_id.

function runOpenAICompatLoop(
    string baseUrl,
    string apiKey,
    string model,
    string systemPrompt,
    string userPrompt,
    AnthropicTool[] tools,
    function (string toolName, json args) returns string toolDispatcher,
    int maxTurns
) returns string|error {
    http:Client openai = check new (baseUrl, timeout = 120);

    json[] messages = [
        {role: "system", content: systemPrompt},
        {role: "user", content: userPrompt}
    ];
    string finalText = "Investigation incomplete — max turns reached.";

    int turn = 0;
    while turn < maxTurns {
        turn += 1;

        // Rebuild tool list each turn — activeTools may grow via discover_tools.
        json[] apiTools = [];
        foreach AnthropicTool t in tools {
            apiTools.push({
                'type: "function",
                'function: {name: t.name, description: t.description, parameters: t.input_schema}
            });
        }

        json requestBody = {
            model: model,
            messages: messages,
            tools: apiTools
        };

        map<string|string[]> headers = {"Content-Type": "application/json"};
        if apiKey != "" {
            headers["Authorization"] = string `Bearer ${apiKey}`;
        }

        http:Response|error resp = openai->post("/v1/chat/completions", requestBody, headers);
        if resp is error {
            return error(string `OpenAI-compat API call failed: ${resp.message()}`);
        }
        json body = check resp.getJsonPayload();
        if resp.statusCode != 200 {
            return error(string `OpenAI-compat API error ${resp.statusCode}: ${body.toJsonString()}`);
        }

        json[] choices = <json[]>(check body.choices);
        if choices.length() == 0 {
            break;
        }
        json choice = choices[0];
        json choiceMsg = check choice.message;

        // Echo assistant message (including tool_calls if present) into history.
        messages.push(choiceMsg);

        json|error toolCallsField = choiceMsg.tool_calls;
        if toolCallsField is json[] && toolCallsField.length() > 0 {
            foreach json tc in toolCallsField {
                string callId = (check tc.id).toString();
                json fn = check tc.'function;
                string toolName = (check fn.name).toString();
                // OpenAI serialises arguments as a JSON string; parse it back to json.
                // Some compatible APIs return an object directly — handle both.
                json argsRaw = check fn.arguments;
                json args;
                if argsRaw is string {
                    args = check value:fromJsonString(argsRaw);
                } else {
                    args = argsRaw;
                }
                log:printInfo("tool call", tool = toolName);
                string result = toolDispatcher(toolName, args);
                // Each tool result is its own message in OpenAI history format.
                messages.push({role: "tool", tool_call_id: callId, content: result});
            }
        } else {
            json|error contentField = choiceMsg.content;
            if contentField is json && !(contentField is ()) {
                string c = contentField.toString();
                if c.trim().length() > 0 && c != "null" {
                    finalText = c;
                }
            }
            break;
        }
    }
    return finalText;
}
