// Copyright (c) 2026 WSO2 LLC (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/ai;
import ballerina/http;

# Configurations for controlling the behaviours when communicating with a remote HTTP endpoint.
@display {label: "Connection Configuration"}
public type ConnectionConfig record {|

    # The HTTP version understood by the client
    @display {label: "HTTP Version"}
    http:HttpVersion httpVersion = http:HTTP_2_0;

    # Configurations related to HTTP/1.x protocol
    @display {label: "HTTP1 Settings"}
    http:ClientHttp1Settings http1Settings?;

    # Configurations related to HTTP/2 protocol
    @display {label: "HTTP2 Settings"}
    http:ClientHttp2Settings http2Settings?;

    # The maximum time to wait (in seconds) for a response before closing the connection
    @display {label: "Timeout"}
    decimal timeout = 60;

    # The choice of setting `forwarded`/`x-forwarded` header
    @display {label: "Forwarded"}
    string forwarded = "disable";

    # Configurations associated with request pooling
    @display {label: "Pool Configuration"}
    http:PoolConfiguration poolConfig?;

    # HTTP caching related configurations
    @display {label: "Cache Configuration"}
    http:CacheConfig cache?;

    # Specifies the way of handling compression (`accept-encoding`) header
    @display {label: "Compression"}
    http:Compression compression = http:COMPRESSION_AUTO;

    # Configurations associated with the behaviour of the Circuit Breaker
    @display {label: "Circuit Breaker Configuration"}
    http:CircuitBreakerConfig circuitBreaker?;

    # Configurations associated with retrying
    @display {label: "Retry Configuration"}
    http:RetryConfig retryConfig?;

    # Configurations associated with inbound response size limits
    @display {label: "Response Limit Configuration"}
    http:ResponseLimitConfigs responseLimits?;

    # SSL/TLS-related options
    @display {label: "Secure Socket Configuration"}
    http:ClientSecureSocket secureSocket?;

    # Proxy server related options
    @display {label: "Proxy Configuration"}
    http:ProxyConfig proxy?;

    # Enables the inbound payload validation functionality which provided by the constraint package. Enabled by default
    @display {label: "Payload Validation"}
    boolean validation = true;
|};

# Authentication configuration for Vertex AI.
# - `OAuth2RefreshConfig` — OAuth2 refresh token flow. HTTP client auto-refreshes forever.
# - `ServiceAccountConfig` — Service account JWT Bearer with inline credentials. Tokens
#                            re-signed and exchanged automatically before expiry.
# - `ServiceAccountJsonFilePath` — Path to a Google Cloud service account JSON key file.
#                                Use `ServiceAccountConfig` instead if you need to override scopes.
public type VertexAiAuth OAuth2RefreshConfig|ServiceAccountConfig|ServiceAccountJsonFilePath;

# Path to a Google Cloud service account JSON key file.
# The connector reads `client_email` and `private_key` from the file and refreshes
# the token automatically. Use `ServiceAccountConfig` if you need to override scopes.
public type ServiceAccountJsonFilePath string;

# Google OAuth2 refresh token credentials. The HTTP client exchanges the refresh
# token for a short-lived access token and renews it transparently before expiry.
# Get credentials via: `gcloud auth application-default login`
# then read `~/.config/gcloud/application_default_credentials.json`.
public type OAuth2RefreshConfig readonly & record {|
    # OAuth2 client ID
    string clientId;
    # OAuth2 client secret
    string clientSecret;
    # Long-lived refresh token (does not expire unless revoked)
    string refreshToken;
    # Token endpoint URL
    string refreshUrl = "https://oauth2.googleapis.com/token";
|};

# Google Cloud Service Account credentials for Vertex AI authentication.
# A new signed JWT is built and exchanged for a fresh access token automatically,
# 5 minutes before the current token expires. Works for long-running services.
public type ServiceAccountConfig readonly & record {|
    # Service account email (`client_email` field in the JSON key file)
    string clientEmail;
    # RSA private key in PEM format (`private_key` field in the JSON key file)
    string privateKey;
    # OAuth2 scopes to request
    string[] scopes = ["https://www.googleapis.com/auth/cloud-platform"];
|};

// Publisher string constants used internally for routing logic.
const string GOOGLE = "google";
const string ANTHROPIC = "anthropic";
const string MISTRAL = "mistralai";
const string META = "meta";
const string DEEPSEEK_AI = "deepseek-ai";
const string QWEN = "qwen";
const string KIMI = "kimi";
const string MINIMAX = "minimax";
const string OPENAI = "openai";

# Embedding model names supported by the Vertex AI embedding provider.
public enum VertexAiEmbeddingModelNames {
    TEXT_EMBEDDING_005 = "text-embedding-005",
    TEXT_MULTILINGUAL_EMBEDDING_002 = "text-multilingual-embedding-002",
    TEXT_EMBEDDING_004 = "text-embedding-004"
}

// ── Internal Vertex AI API types ──────────────────────────────────────────────

# Represents a single part of a Vertex AI content block.
type VertexAiPart record {
    string text?;
    VertexAiBlob inlineData?;
    VertexAiFunctionCall functionCall?;
    VertexAiFunctionResponse functionResponse?;
};

# Represents inline binary data (e.g., an image encoded in base64).
type VertexAiBlob record {
    string mimeType;
    string data; // base64-encoded
};

# Represents a function call returned by the model.
type VertexAiFunctionCall record {
    string name;
    map<json> args?;
};

# Represents a function response provided to the model.
type VertexAiFunctionResponse record {
    string name;
    map<json> response;
};

# Represents a content object containing a role and one or more parts.
type VertexAiContent record {
    string role;
    VertexAiPart[] parts;
};

# Represents the systemInstruction field in a Vertex AI request.
# Vertex AI expects role "user" on the systemInstruction object.
type VertexAiSystemInstruction record {
    string role = "user";
    VertexAiPart[] parts;
};

# Represents a single function declaration for tool use.
type VertexAiFunctionDeclaration record {
    string name;
    string description;
    map<json> parameters?;
};

# Represents a tool with one or more function declarations.
type VertexAiTool record {
    VertexAiFunctionDeclaration[] functionDeclarations;
};

# Configures the function calling behaviour.
type VertexAiFunctionCallingConfig record {
    string mode; // AUTO, ANY, NONE
    string[] allowedFunctionNames?;
};

# Top-level tool configuration.
type VertexAiToolConfig record {
    VertexAiFunctionCallingConfig functionCallingConfig;
};

# Vertex AI generation configuration parameters.
type VertexAiGenerationConfig record {
    decimal temperature?;
    int maxOutputTokens?;
    string[] stopSequences?;
};

# The full Vertex AI generateContent request body.
type VertexAiRequest record {
    VertexAiContent[] contents;
    VertexAiSystemInstruction systemInstruction?;
    VertexAiTool[] tools?;
    VertexAiToolConfig toolConfig?;
    VertexAiGenerationConfig generationConfig?;
};

# A single candidate in the Vertex AI response.
type VertexAiCandidate record {
    VertexAiContent content?;
    string finishReason?;
    int index?;
};

# Token usage metadata returned in the Vertex AI response.
type VertexAiUsageMetadata record {
    int promptTokenCount?;
    int candidatesTokenCount?;
    int totalTokenCount?;
};

# The full Vertex AI generateContent response body.
type VertexAiResponse record {
    VertexAiCandidate[] candidates?;
    VertexAiUsageMetadata usageMetadata?;
    string responseId?;
    string modelVersion?;
};

# Vertex AI :predict response for embedding models.
type VertexAiPredictEmbedResponse record {
    VertexAiPredictEmbedPrediction[] predictions;
};

# A single prediction entry in the :predict embedding response.
type VertexAiPredictEmbedPrediction record {
    VertexAiPredictEmbedding embeddings;
};

# The embedding values returned by Vertex AI.
type VertexAiPredictEmbedding record {
    float[] values;
};

// ── Anthropic on Vertex internal types ────────────────────────────────────────
// Anthropic models on Vertex AI use the rawPredict endpoint with the Anthropic
// Messages API wire format. The version is sent as a request body field instead
// of a header (unlike the direct Anthropic API).

# A single message in the Anthropic Messages API format.
type AnthropicMessage record {
    string role;
    string|AnthropicContentBlock[] content;
};

# A content block in an Anthropic message (text, tool_use, or tool_result).
type AnthropicContentBlock record {
    string 'type;
    string text?;
    string id?;
    string name?;
    json input?;
    string tool_use_id?;
    string content?;
};

# An Anthropic tool definition (uses input_schema instead of parameters).
type AnthropicTool record {
    string name;
    string description;
    map<json> input_schema;
};

# Forces the model to call a specific Anthropic tool.
type AnthropicToolChoice record {
    string 'type;
    string name?;
};

# Token usage information from the Anthropic response.
type AnthropicUsage record {
    int input_tokens?;
    int output_tokens?;
};

# The Anthropic rawPredict response body.
type AnthropicResponse record {
    string id?;
    AnthropicContentBlock[] content;
    string stop_reason?;
    AnthropicUsage usage?;
};

// ── Mistral on Vertex internal types ──────────────────────────────────────────
// Mistral models on Vertex AI use the rawPredict endpoint with an
// OpenAI-compatible wire format. The model name is sent in the request body.

# A single message in the Mistral/OpenAI-compatible format.
# `content` is doubly-optional: nilable (string?) because assistant messages with tool calls
# omit content entirely, and record-optional (?) to allow the field to be absent in the JSON.
type MistralMessage record {
    string role;
    string? content?;
    string? tool_call_id?;
    MistralToolCall[]? tool_calls?;
};

# A tool call entry in a Mistral assistant message.
type MistralToolCall record {
    string id?;
    string 'type?;
    MistralFunction 'function;
};

# The function name and JSON-encoded arguments from a Mistral tool call.
type MistralFunction record {
    string name;
    string arguments;
};

# A Mistral tool definition (OpenAI-compatible function format).
type MistralTool record {
    string 'type = "function";
    MistralFunctionDeclaration 'function;
};

# The function declaration inside a Mistral tool.
type MistralFunctionDeclaration record {
    string name;
    string description;
    map<json> parameters?;
};

# A single candidate choice in the Mistral response.
type MistralChoice record {
    int index?;
    MistralMessage message;
    string? finish_reason?;
};

# Token usage information from the Mistral response.
type MistralUsage record {
    int prompt_tokens?;
    int completion_tokens?;
};

# The Mistral rawPredict response body.
type MistralResponse record {
    string id?;
    MistralChoice[] choices;
    MistralUsage usage?;
};

// ── Internal result type ───────────────────────────────────────────────────────

# Carries the chat assistant message alongside the token-usage metadata from
# the raw provider response, so that chat() can update the observability span
# after dispatch without requiring each publisher path to hold a span reference.
type ChatResult record {|
    ai:ChatAssistantMessage message;
    string responseId;
    int? inputTokens;
    int? outputTokens;
|};

// ── Anthropic on Vertex streaming event types ─────────────────────────────────
// Anthropic's `:streamRawPredict` endpoint emits its native Messages API SSE
// event stream: message_start, content_block_start, content_block_delta,
// content_block_stop, message_delta, message_stop, ping. Open records tolerate
// the fields that are only present on some event types.

# A single SSE event from the Anthropic Messages API stream, discriminated by `type`.
type AnthropicStreamEvent record {
    string 'type;
    AnthropicStreamMessage message?;
    int index?;
    AnthropicStreamContentBlock content_block?;
    AnthropicStreamDelta delta?;
    AnthropicUsage usage?;
};

# The message snapshot carried by a `message_start` event.
type AnthropicStreamMessage record {
    string id?;
    AnthropicUsage usage?;
};

# The content block carried by a `content_block_start` event.
type AnthropicStreamContentBlock record {
    string 'type;
    string id?;
    string name?;
};

# The delta carried by `content_block_delta` (text_delta/input_json_delta) or
# `message_delta` (stop_reason) events.
type AnthropicStreamDelta record {
    string 'type?;
    string text?;
    string partial_json?;
    string stop_reason?;
};

// ── Mistral/OpenAI-compatible streaming chunk types ───────────────────────────
// Shared by Mistral (`:streamRawPredict`) and the open-models endpoint
// (Meta/DeepSeek/Qwen/Kimi/MiniMax/OpenAI), both of which stream OpenAI-style
// `chat.completion.chunk` SSE events.

# A single streamed chunk in the OpenAI-compatible `chat.completion.chunk` shape.
type MistralStreamChunk record {
    string id?;
    MistralStreamChoice[] choices;
    MistralUsage usage?;
};

# A single choice within a streamed OpenAI-compatible chunk.
type MistralStreamChoice record {
    int index?;
    MistralChunkDelta delta;
    string? finish_reason?;
};

# The incremental message delta for a streamed OpenAI-compatible choice.
type MistralChunkDelta record {
    string role?;
    string? content?;
    MistralToolCallChunk[] tool_calls?;
};

# An incremental tool call fragment within a streamed OpenAI-compatible delta.
type MistralToolCallChunk record {
    int index;
    string id?;
    string 'type?;
    MistralFunctionChunk 'function?;
};

# The function name/arguments fragment of a streamed OpenAI-compatible tool call.
type MistralFunctionChunk record {
    string name?;
    string arguments?;
};

// ── Wire → normalized mapping ──────────────────────────────────────────────
// Projects each publisher's native streamed chunk/event onto the normalized
// `ai:ChatCompletionChunk` that `chatStream` must return.

# Maps a Vertex AI Gemini streamed chunk onto the normalized `ai:ChatCompletionChunk`.
# Gemini does not fragment function-call arguments across chunks the way OpenAI/Anthropic
# do, so each function-call part gets its own index within the chunk.
#
# + w - The parsed Gemini streaming wire chunk (one SSE event)
# + return - The normalized chunk consumed by the `ai` module
isolated function toAiChunkGemini(VertexAiResponse w) returns ai:ChatCompletionChunk {
    ai:ChatCompletionChunkChoice[] choices = [];
    VertexAiCandidate[]? candidates = w.candidates;
    if candidates is VertexAiCandidate[] {
        foreach VertexAiCandidate c in candidates {
            string textAccumulator = "";
            ai:ToolCallChunk[] toolCalls = [];
            VertexAiContent? content = c.content;
            if content is VertexAiContent {
                int idx = 0;
                foreach VertexAiPart part in content.parts {
                    string? text = part.text;
                    if text is string {
                        textAccumulator += text;
                    }
                    VertexAiFunctionCall? fc = part.functionCall;
                    if fc is VertexAiFunctionCall {
                        toolCalls.push({
                            index: idx,
                            'function: {name: fc.name, arguments: (fc.args ?: {}).toJsonString()}
                        });
                        idx += 1;
                    }
                }
            }
            ai:ChatCompletionChunkDelta delta = {content: textAccumulator.length() > 0 ? textAccumulator : ()};
            if toolCalls.length() > 0 {
                delta.toolCalls = toolCalls;
            }
            choices.push({
                index: c.index ?: 0,
                delta,
                finishReason: mapGeminiFinishReason(c.finishReason, toolCalls.length() > 0)
            });
        }
    }

    ai:ChatCompletionChunk chunk = {choices};
    string? responseId = w.responseId;
    if responseId is string {
        chunk.id = responseId;
    }
    string? modelVersion = w.modelVersion;
    if modelVersion is string {
        chunk.model = modelVersion;
    }
    VertexAiUsageMetadata? usage = w.usageMetadata;
    if usage is VertexAiUsageMetadata {
        chunk.usage = {
            promptTokens: usage.promptTokenCount,
            completionTokens: usage.candidatesTokenCount,
            totalTokens: usage.totalTokenCount
        };
    }
    return chunk;
}

# Safely maps a Gemini `finishReason` string onto the `ai:FinishReason` enum.
# Gemini has no explicit "tool calls" finish reason; a plain `STOP` accompanied
# by a function-call part is reported as `ai:TOOL_CALLS` instead.
#
# + finishReason - The finish reason string from the candidate
# + hasToolCalls - Whether this chunk's candidate carried any function-call parts
# + return - The mapped `ai:FinishReason`, or `()` when absent/unrecognized
isolated function mapGeminiFinishReason(string? finishReason, boolean hasToolCalls) returns ai:FinishReason? {
    if finishReason is () {
        return ();
    }
    if finishReason == "STOP" {
        return hasToolCalls ? ai:TOOL_CALLS : ai:STOP;
    }
    if finishReason == "MAX_TOKENS" {
        return ai:LENGTH;
    }
    if finishReason == "SAFETY" || finishReason == "RECITATION" || finishReason == "BLOCKLIST" ||
            finishReason == "PROHIBITED_CONTENT" || finishReason == "SPII" {
        return ai:CONTENT_FILTER;
    }
    return ();
}

# Maps a single Anthropic Messages API stream event onto a normalized
# `ai:ChatCompletionChunk`. Several event types (block-stop, ping, lifecycle
# bookkeeping) carry no data for the normalized shape and yield `()`.
#
# + event - The parsed Anthropic stream event
# + promptTokens - Prompt token count captured from the `message_start` event, if any;
#                  threaded through so the final `message_delta` chunk can report full usage
# + return - The normalized chunk, or `()` if this event maps to no chunk
isolated function toAiChunkAnthropicEvent(AnthropicStreamEvent event, int? promptTokens)
        returns ai:ChatCompletionChunk? {
    if event.'type == "message_start" {
        return {choices: [{index: 0, delta: {role: ai:ASSISTANT}}]};
    }
    if event.'type == "content_block_start" {
        AnthropicStreamContentBlock? block = event.content_block;
        if block is AnthropicStreamContentBlock && block.'type == "tool_use" {
            ai:ToolCallChunk toolCall = {index: event.index ?: 0};
            string? id = block.id;
            if id is string {
                toolCall.id = id;
            }
            string? name = block.name;
            if name is string {
                toolCall.'function = {name};
            }
            return {choices: [{index: 0, delta: {toolCalls: [toolCall]}}]};
        }
        return ();
    }
    if event.'type == "content_block_delta" {
        AnthropicStreamDelta? delta = event.delta;
        if delta is AnthropicStreamDelta {
            if delta.'type == "text_delta" {
                return {choices: [{index: 0, delta: {content: delta.text}}]};
            }
            if delta.'type == "input_json_delta" {
                ai:ToolCallChunk toolCall = {index: event.index ?: 0, 'function: {arguments: delta.partial_json ?: ""}};
                return {choices: [{index: 0, delta: {toolCalls: [toolCall]}}]};
            }
        }
        return ();
    }
    if event.'type == "message_delta" {
        AnthropicStreamDelta? delta = event.delta;
        ai:FinishReason? finishReason = delta is AnthropicStreamDelta ? mapAnthropicStopReason(delta.stop_reason) : ();
        ai:ChatCompletionChunk chunk = {choices: [{index: 0, delta: {}, finishReason}]};
        int? completionTokens = event.usage?.output_tokens;
        if promptTokens is int || completionTokens is int {
            chunk.usage = {
                promptTokens,
                completionTokens,
                totalTokens: (promptTokens ?: 0) + (completionTokens ?: 0)
            };
        }
        return chunk;
    }
    if event.'type == "error" {
        // Surfaced as an error by the iterator, not reached via this mapping function.
        return ();
    }
    // content_block_stop, message_stop, ping, and any other lifecycle events carry no data.
    return ();
}

# Safely maps an Anthropic `stop_reason` onto the `ai:FinishReason` enum.
#
# + stopReason - The stop reason string from the `message_delta` event
# + return - The mapped `ai:FinishReason`, or `()` when absent/unrecognized
isolated function mapAnthropicStopReason(string? stopReason) returns ai:FinishReason? {
    if stopReason is () {
        return ();
    }
    if stopReason == "end_turn" || stopReason == "stop_sequence" {
        return ai:STOP;
    }
    if stopReason == "max_tokens" {
        return ai:LENGTH;
    }
    if stopReason == "tool_use" {
        return ai:TOOL_CALLS;
    }
    return ();
}

# Maps a streamed OpenAI-compatible chunk (Mistral or an open-models publisher)
# onto the normalized `ai:ChatCompletionChunk`. Forwards tool calls on every
# chunk (not just the first), so argument fragments stream through correctly.
#
# + w - The parsed OpenAI-compatible streaming wire chunk
# + return - The normalized chunk consumed by the `ai` module
isolated function toAiChunkOpenAiCompat(MistralStreamChunk w) returns ai:ChatCompletionChunk {
    ai:ChatCompletionChunkChoice[] choices = [];
    foreach MistralStreamChoice c in w.choices {
        ai:ChatCompletionChunkDelta delta = {content: c.delta?.content};
        ai:ROLE? role = mapRole(c.delta?.role);
        if role is ai:ROLE {
            delta.role = role;
        }
        MistralToolCallChunk[]? wireToolCalls = c.delta?.tool_calls;
        if wireToolCalls is MistralToolCallChunk[] {
            ai:ToolCallChunk[] toolCalls = [];
            foreach MistralToolCallChunk t in wireToolCalls {
                ai:ToolCallChunk toolCall = {index: t.index};
                string? id = t?.id;
                if id is string {
                    toolCall.id = id;
                }
                MistralFunctionChunk? fn = t?.'function;
                if fn is MistralFunctionChunk {
                    ai:FunctionCallChunk functionFragment = {};
                    string? name = fn?.name;
                    if name is string {
                        functionFragment.name = name;
                    }
                    string? args = fn?.arguments;
                    if args is string {
                        functionFragment.arguments = args;
                    }
                    toolCall.'function = functionFragment;
                }
                toolCalls.push(toolCall);
            }
            delta.toolCalls = toolCalls;
        }
        choices.push({index: c?.index ?: 0, delta, finishReason: mapOpenAiCompatFinishReason(c?.finish_reason)});
    }

    ai:ChatCompletionChunk chunk = {choices};
    string? id = w.id;
    if id is string {
        chunk.id = id;
    }
    MistralUsage? usage = w.usage;
    if usage is MistralUsage {
        chunk.usage = {promptTokens: usage.prompt_tokens, completionTokens: usage.completion_tokens};
    }
    return chunk;
}

# Safely maps an OpenAI-compatible role string onto the `ai:ROLE` enum; returns
# `()` for absent or unrecognized values rather than panicking on a cast.
#
# + role - The role string from the wire delta
# + return - The mapped `ai:ROLE`, or `()` when absent/unrecognized
isolated function mapRole(string? role) returns ai:ROLE? {
    match role {
        "system" => {
            return ai:SYSTEM;
        }
        "user" => {
            return ai:USER;
        }
        "assistant" => {
            return ai:ASSISTANT;
        }
    }
    return ();
}

# Safely maps an OpenAI-compatible `finish_reason` onto the `ai:FinishReason` enum.
#
# + finishReason - The finish reason string from the wire chunk
# + return - The mapped `ai:FinishReason`, or `()` when absent/unrecognized
isolated function mapOpenAiCompatFinishReason(string? finishReason) returns ai:FinishReason? {
    if finishReason == "stop" {
        return ai:STOP;
    }
    if finishReason == "length" {
        return ai:LENGTH;
    }
    if finishReason == "tool_calls" {
        return ai:TOOL_CALLS;
    }
    if finishReason == "content_filter" {
        return ai:CONTENT_FILTER;
    }
    return ();
}
