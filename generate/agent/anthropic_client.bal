// Anthropic Messages API client — implements the tool-use agent loop.

import ballerina/http;
import ballerina/log;

// Anthropic tool definition (subset needed for MCP tool forwarding).
type AnthropicTool record {|
    string name;
    string description;
    json input_schema;
|};

// Anthropic message content block types.
type TextBlock record {|
    string 'type = "text";
    string text;
|};

type ToolUseBlock record {|
    string 'type = "tool_use";
    string id;
    string name;
    json input;
|};

type ToolResultBlock record {|
    string 'type = "tool_result";
    string tool_use_id;
    string content;
|};

// Run the Anthropic agent loop. Returns the final text response.
function runAgentLoop(
    string apiKey,
    string model,
    string systemPrompt,
    string userPrompt,
    AnthropicTool[] tools,
    function (string toolName, json args) returns string toolDispatcher,
    int maxTurns
) returns string|error {
    // AMP injects ANTHROPIC_URL pointing to its AI gateway proxy; fall back to direct.
    string anthropicBaseUrl = envOr("ANTHROPIC_URL", "https://api.anthropic.com");
    http:Client anthropicClient = check new (anthropicBaseUrl, timeout = 120);

    json[] messages = [{role: "user", content: userPrompt}];
    string finalText = "Investigation incomplete — max turns reached.";

    int turn = 0;
    while turn < maxTurns {
        turn += 1;

        // Build tool list for Anthropic API.
        json[] apiTools = [];
        foreach AnthropicTool t in tools {
            apiTools.push({name: t.name, description: t.description, input_schema: t.input_schema});
        }

        json requestBody = {
            model: model,
            max_tokens: 8192,
            system: systemPrompt,
            messages: messages,
            tools: apiTools
        };

        http:Response|error resp = anthropicClient->post("/v1/messages", requestBody, {
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
            "Content-Type": "application/json"
        });
        if resp is error {
            return error(string `Anthropic API call failed: ${resp.message()}`);
        }
        json body = check resp.getJsonPayload();
        if resp.statusCode != 200 {
            return error(string `Anthropic API error ${resp.statusCode}: ${body.toJsonString()}`);
        }

        string stopReason = (check body.stop_reason).toString();
        json[] content = <json[]>(check body.content);

        // Append assistant message.
        messages.push({role: "assistant", content: content});

        if stopReason == "end_turn" {
            // Extract text from the last assistant message.
            foreach json block in content {
                string blockType = (check block.'type).toString();
                if blockType == "text" {
                    finalText = (check block.text).toString();
                }
            }
            break;
        }

        if stopReason == "tool_use" {
            json[] toolResults = [];
            foreach json block in content {
                string blockType = (check block.'type).toString();
                if blockType == "tool_use" {
                    string toolId = (check block.id).toString();
                    string toolName = (check block.name).toString();
                    json toolInput = check block.input;
                    log:printInfo("tool call", tool = toolName);
                    string result = toolDispatcher(toolName, toolInput);
                    toolResults.push({'type: "tool_result", tool_use_id: toolId, content: result});
                }
            }
            messages.push({role: "user", content: toolResults});
        } else {
            break;
        }
    }
    return finalText;
}
