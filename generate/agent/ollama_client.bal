// Pluggable LLM backend. LLM_PROVIDER selects the engine:
//   anthropic (default) -> Anthropic Messages API tool-use loop (anthropic_client.bal)
//   ollama              -> local Ollama /api/chat tool-calling loop (below)
// Both share the same tool list (AnthropicTool[]) and dispatcher signature, so the
// agent code in devops_oversight_agent.bal is provider-agnostic.

import ballerina/http;
import ballerina/log;

// Select the configured backend and run the agent loop.
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

    // Default: Anthropic Claude (direct Messages API).
    string apiKey = envOr("ANTHROPIC_API_KEY", "");
    if apiKey == "" {
        return error("ANTHROPIC_API_KEY not set (LLM_PROVIDER=anthropic). Set a real sk-ant-api03 key or switch LLM_PROVIDER=ollama.");
    }
    string model = envOr("AGENT_MODEL", "claude-sonnet-4-6");
    log:printInfo("LLM provider: anthropic", model = model);
    return runAgentLoop(apiKey, model, systemPrompt, userPrompt, tools, toolDispatcher, maxTurns);
}

// Ollama tool-use loop using the native /api/chat endpoint (OpenAI-style function
// specs in, message.tool_calls out — arguments arrive as a JSON object, not a string).
// Requires a tool-calling-capable model (e.g. qwen3.5, qwen3, llama3.1).
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

    // Translate our tool list into Ollama's OpenAI-style function specs.
    json[] ollamaTools = [];
    foreach AnthropicTool t in tools {
        ollamaTools.push({
            'type: "function",
            'function: {name: t.name, description: t.description, parameters: t.input_schema}
        });
    }

    json[] messages = [
        {role: "system", content: systemPrompt},
        {role: "user", content: userPrompt}
    ];
    string finalText = "Investigation incomplete — max turns reached.";

    int turn = 0;
    while turn < maxTurns {
        turn += 1;

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
        // Echo the assistant turn back into history (carries any tool_calls).
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
