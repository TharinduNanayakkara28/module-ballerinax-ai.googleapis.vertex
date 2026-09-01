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

import ballerina/http;
import ballerina/test;

// ── Streaming mock services ─────────────────────────────────────────────────
// Each service below returns a canned Server-Sent Event stream in the exact
// wire format the corresponding publisher's real streaming endpoint emits, so
// chatStream()/generateStream() and their iterators/toAiChunk* mapping
// functions are exercised end-to-end without a live API key. Scenarios are
// split across dedicated ports (rather than branching on request content) to
// keep each mock service trivial to read.

isolated function toSseStream(string[] dataLines) returns stream<http:SseEvent, error?> {
    http:SseEvent[] events = dataLines.map(d => {data: d});
    return stream from http:SseEvent e in events
        select e;
}

isolated function assertBearerAuth(string authHeader) {
    test:assertTrue(authHeader.startsWith("Bearer "), "Authorization header must start with 'Bearer '");
}

// The mock resource paths capture the whole final path segment, so the `:streamGenerateContent`
// / `:streamRawPredict` action suffix lands in `modelId` rather than being matched by the
// router. These assertions pin it down, so routing a publisher to the wrong streaming
// action fails a test instead of passing silently.
isolated function assertStreamAction(string modelId, string expectedAction) {
    test:assertTrue(modelId.endsWith(expectedAction),
            string `expected the request path to use '${expectedAction}', got model segment '${modelId}'`);
}

// Gemini signals streaming through the endpoint action and `?alt=sse`, never a body flag.
isolated function assertGeminiStreamPayload(json payload) {
    test:assertTrue(payload is map<json>, "expected a JSON object payload");
    if payload is map<json> {
        test:assertFalse(payload.hasKey("stream"), "Gemini must not send a 'stream' body flag");
    }
}

// Anthropic and the OpenAI-compatible endpoints both stream on a `stream: true` body flag.
isolated function assertStreamFlag(json payload) {
    test:assertTrue(payload is map<json>, "expected a JSON object payload");
    if payload is map<json> {
        test:assertEquals(payload["stream"], true, "the streaming request must set 'stream': true");
    }
}

// The OpenAI-compatible endpoints omit `usage` from a stream unless it is opted into.
isolated function assertUsageOptIn(json payload) {
    assertStreamFlag(payload);
    if payload is map<json> {
        test:assertEquals(payload["stream_options"], {"include_usage": true},
                "the streaming request must opt in to usage reporting");
    }
}

// ── Gemini streaming (text-only) — port 8090 ───────────────────────────────
// Used by testGeminiChatStreamText and testGeminiGenerateStream.
final json GEMINI_TEXT_CHUNK_1 = {
    "candidates": [{"content": {"role": "model", "parts": [{"text": "Hello"}]}, "index": 0}],
    "responseId": "gemini-stream-text"
};
final json GEMINI_TEXT_CHUNK_2 = {
    "candidates": [{"content": {"role": "model", "parts": [{"text": ", world!"}]}, "index": 0}],
    "responseId": "gemini-stream-text"
};
final json GEMINI_TEXT_CHUNK_FINAL = {
    "candidates": [{"content": {"role": "model", "parts": []}, "finishReason": "STOP", "index": 0}],
    "usageMetadata": {"promptTokenCount": 5, "candidatesTokenCount": 10, "totalTokenCount": 15},
    "responseId": "gemini-stream-text",
    "modelVersion": "gemini-2.0-flash"
};

service /llm/vertexai on new http:Listener(8090) {
    resource function post v1/projects/[string projectId]/locations/[string location]/publishers/google/models/[string modelId](
            @http:Header {name: "Authorization"} string authHeader,
            @http:Payload json payload) returns stream<http:SseEvent, error?> {
        assertBearerAuth(authHeader);
        assertStreamAction(modelId, ":streamGenerateContent");
        assertGeminiStreamPayload(payload);
        return toSseStream([
            GEMINI_TEXT_CHUNK_1.toJsonString(),
            GEMINI_TEXT_CHUNK_2.toJsonString(),
            GEMINI_TEXT_CHUNK_FINAL.toJsonString()
        ]);
    }
}

// ── Gemini streaming (tool call) — port 8094 ───────────────────────────────
// Gemini does not fragment function-call arguments across chunks, so the
// whole call arrives complete in a single event.
final json GEMINI_TOOL_CHUNK = {
    "candidates": [{
        "content": {
            "role": "model",
            "parts": [{"functionCall": {"name": "get_weather", "args": {"city": "Colombo"}}}]
        },
        "finishReason": "STOP",
        "index": 0
    }],
    "usageMetadata": {"promptTokenCount": 8, "candidatesTokenCount": 6, "totalTokenCount": 14},
    "responseId": "gemini-stream-tool"
};

service /llm/vertexai on new http:Listener(8094) {
    resource function post v1/projects/[string projectId]/locations/[string location]/publishers/google/models/[string modelId](
            @http:Header {name: "Authorization"} string authHeader,
            @http:Payload json payload) returns stream<http:SseEvent, error?> {
        assertBearerAuth(authHeader);
        assertStreamAction(modelId, ":streamGenerateContent");
        assertGeminiStreamPayload(payload);
        return toSseStream([GEMINI_TOOL_CHUNK.toJsonString()]);
    }
}

// ── Anthropic streaming (text-only) — port 8091 ────────────────────────────
// Used by testAnthropicChatStreamText and testAnthropicGenerateStream.
final json ANTH_TEXT_MSG_START = {
    "type": "message_start",
    "message": {"id": "msg-stream-text", "usage": {"input_tokens": 10}}
};
final json ANTH_TEXT_BLOCK_START = {"type": "content_block_start", "index": 0, "content_block": {"type": "text"}};
final json ANTH_TEXT_DELTA_1 = {
    "type": "content_block_delta",
    "index": 0,
    "delta": {"type": "text_delta", "text": "Hello"}
};
final json ANTH_TEXT_DELTA_2 = {
    "type": "content_block_delta",
    "index": 0,
    "delta": {"type": "text_delta", "text": ", world!"}
};
final json ANTH_TEXT_BLOCK_STOP = {"type": "content_block_stop", "index": 0};
final json ANTH_TEXT_MSG_DELTA = {
    "type": "message_delta",
    "delta": {"stop_reason": "end_turn"},
    "usage": {"output_tokens": 8}
};
final json ANTH_TEXT_MSG_STOP = {"type": "message_stop"};

service /llm/vertexai on new http:Listener(8091) {
    resource function post v1/projects/[string projectId]/locations/[string location]/publishers/anthropic/models/[string modelId](
            @http:Header {name: "Authorization"} string authHeader,
            @http:Payload json payload) returns stream<http:SseEvent, error?> {
        assertBearerAuth(authHeader);
        assertStreamAction(modelId, ":streamRawPredict");
        assertStreamFlag(payload);
        return toSseStream([
            ANTH_TEXT_MSG_START.toJsonString(),
            ANTH_TEXT_BLOCK_START.toJsonString(),
            ANTH_TEXT_DELTA_1.toJsonString(),
            ANTH_TEXT_DELTA_2.toJsonString(),
            ANTH_TEXT_BLOCK_STOP.toJsonString(),
            ANTH_TEXT_MSG_DELTA.toJsonString(),
            ANTH_TEXT_MSG_STOP.toJsonString()
        ]);
    }
}

// ── Anthropic streaming (tool call) — port 8095 ────────────────────────────
// Tool id/name arrive on content_block_start; arguments stream as
// input_json_delta fragments on content_block_delta, keyed by block index.
final json ANTH_TOOL_MSG_START = {
    "type": "message_start",
    "message": {"id": "msg-stream-tool", "usage": {"input_tokens": 15}}
};
final json ANTH_TOOL_BLOCK_START = {
    "type": "content_block_start",
    "index": 0,
    "content_block": {"type": "tool_use", "id": "toolu_1", "name": "get_weather"}
};
final json ANTH_TOOL_ARG_DELTA_1 = {
    "type": "content_block_delta",
    "index": 0,
    "delta": {"type": "input_json_delta", "partial_json": "{\"city\":"}
};
final json ANTH_TOOL_ARG_DELTA_2 = {
    "type": "content_block_delta",
    "index": 0,
    "delta": {"type": "input_json_delta", "partial_json": "\"Colombo\"}"}
};
final json ANTH_TOOL_BLOCK_STOP = {"type": "content_block_stop", "index": 0};
final json ANTH_TOOL_MSG_DELTA = {
    "type": "message_delta",
    "delta": {"stop_reason": "tool_use"},
    "usage": {"output_tokens": 12}
};
final json ANTH_TOOL_MSG_STOP = {"type": "message_stop"};

service /llm/vertexai on new http:Listener(8095) {
    resource function post v1/projects/[string projectId]/locations/[string location]/publishers/anthropic/models/[string modelId](
            @http:Header {name: "Authorization"} string authHeader,
            @http:Payload json payload) returns stream<http:SseEvent, error?> {
        assertBearerAuth(authHeader);
        assertStreamAction(modelId, ":streamRawPredict");
        assertStreamFlag(payload);
        return toSseStream([
            ANTH_TOOL_MSG_START.toJsonString(),
            ANTH_TOOL_BLOCK_START.toJsonString(),
            ANTH_TOOL_ARG_DELTA_1.toJsonString(),
            ANTH_TOOL_ARG_DELTA_2.toJsonString(),
            ANTH_TOOL_BLOCK_STOP.toJsonString(),
            ANTH_TOOL_MSG_DELTA.toJsonString(),
            ANTH_TOOL_MSG_STOP.toJsonString()
        ]);
    }
}

// ── Mistral streaming (text-only) — port 8092 ──────────────────────────────
// Used by testMistralChatStreamText and testMistralGenerateStream.
final json MISTRAL_TEXT_ROLE_CHUNK = {
    "id": "chatcmpl-stream-text",
    "choices": [{"index": 0, "delta": {"role": "assistant"}}]
};
final json MISTRAL_TEXT_CHUNK_1 = {
    "id": "chatcmpl-stream-text",
    "choices": [{"index": 0, "delta": {"content": "Hello"}}]
};
final json MISTRAL_TEXT_CHUNK_2 = {
    "id": "chatcmpl-stream-text",
    "choices": [{"index": 0, "delta": {"content": ", world!"}}]
};
final json MISTRAL_TEXT_CHUNK_FINAL = {
    "id": "chatcmpl-stream-text",
    "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
    "usage": {"prompt_tokens": 5, "completion_tokens": 10}
};

service /llm/vertexai on new http:Listener(8092) {
    resource function post v1/projects/[string projectId]/locations/[string location]/publishers/mistralai/models/[string modelId](
            @http:Header {name: "Authorization"} string authHeader,
            @http:Payload json payload) returns stream<http:SseEvent, error?> {
        assertBearerAuth(authHeader);
        assertStreamAction(modelId, ":streamRawPredict");
        assertUsageOptIn(payload);
        return toSseStream([
            MISTRAL_TEXT_ROLE_CHUNK.toJsonString(),
            MISTRAL_TEXT_CHUNK_1.toJsonString(),
            MISTRAL_TEXT_CHUNK_2.toJsonString(),
            MISTRAL_TEXT_CHUNK_FINAL.toJsonString(),
            "[DONE]"
        ]);
    }
}

// ── Mistral streaming (tool call) — port 8096 ──────────────────────────────
// Tool id/name arrive on the first delta; arguments fragment across
// subsequent deltas, all keyed by the same tool_calls[].index.
final json MISTRAL_TOOL_START_CHUNK = {
    "id": "chatcmpl-stream-tool",
    "choices": [{
        "index": 0,
        "delta": {
            "role": "assistant",
            "tool_calls": [{"index": 0, "id": "call_1", "type": "function", "function": {"name": "get_weather", "arguments": ""}}]
        }
    }]
};
final json MISTRAL_TOOL_ARG_CHUNK_1 = {
    "id": "chatcmpl-stream-tool",
    "choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "function": {"arguments": "{\"city\":"}}]}}]
};
final json MISTRAL_TOOL_ARG_CHUNK_2 = {
    "id": "chatcmpl-stream-tool",
    "choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "function": {"arguments": "\"Colombo\"}"}}]}}]
};
final json MISTRAL_TOOL_FINAL_CHUNK = {
    "id": "chatcmpl-stream-tool",
    "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]
};

service /llm/vertexai on new http:Listener(8096) {
    resource function post v1/projects/[string projectId]/locations/[string location]/publishers/mistralai/models/[string modelId](
            @http:Header {name: "Authorization"} string authHeader,
            @http:Payload json payload) returns stream<http:SseEvent, error?> {
        assertBearerAuth(authHeader);
        assertStreamAction(modelId, ":streamRawPredict");
        assertUsageOptIn(payload);
        return toSseStream([
            MISTRAL_TOOL_START_CHUNK.toJsonString(),
            MISTRAL_TOOL_ARG_CHUNK_1.toJsonString(),
            MISTRAL_TOOL_ARG_CHUNK_2.toJsonString(),
            MISTRAL_TOOL_FINAL_CHUNK.toJsonString(),
            "[DONE]"
        ]);
    }
}

// ── Open-model streaming (text-only) — port 8093 ───────────────────────────
// Meta/DeepSeek/Qwen/Kimi/MiniMax all route through this same
// openapi/chat/completions endpoint and wire format; DeepSeek is used here
// as the representative publisher. Shares toAiChunkOpenAiCompat with Mistral,
// so only the text scenario is covered here (tool-call streaming through
// that same mapping function is already exercised by the Mistral tests above).
final json OPEN_MODEL_TEXT_ROLE_CHUNK = {
    "id": "chatcmpl-open-text",
    "choices": [{"index": 0, "delta": {"role": "assistant"}}]
};
final json OPEN_MODEL_TEXT_CHUNK_1 = {
    "id": "chatcmpl-open-text",
    "choices": [{"index": 0, "delta": {"content": "Hi"}}]
};
final json OPEN_MODEL_TEXT_CHUNK_2 = {
    "id": "chatcmpl-open-text",
    "choices": [{"index": 0, "delta": {"content": " there!"}}]
};
final json OPEN_MODEL_TEXT_CHUNK_FINAL = {
    "id": "chatcmpl-open-text",
    "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
    "usage": {"prompt_tokens": 4, "completion_tokens": 6}
};

service /llm/vertexai on new http:Listener(8093) {
    resource function post v1beta1/projects/[string projectId]/locations/[string location]/endpoints/openapi/chat/completions(
            @http:Header {name: "Authorization"} string authHeader,
            @http:Payload json payload) returns stream<http:SseEvent, error?> {
        assertBearerAuth(authHeader);
        assertUsageOptIn(payload);
        return toSseStream([
            OPEN_MODEL_TEXT_ROLE_CHUNK.toJsonString(),
            OPEN_MODEL_TEXT_CHUNK_1.toJsonString(),
            OPEN_MODEL_TEXT_CHUNK_2.toJsonString(),
            OPEN_MODEL_TEXT_CHUNK_FINAL.toJsonString(),
            "[DONE]"
        ]);
    }
}

// ── Failure-path and edge-case mocks ────────────────────────────────────────
// The happy-path services above cannot catch a dropped HTTP status, a stream cut short
// mid-generation, or a garbled frame - each of those reaches the caller as a clean,
// silently truncated answer unless the iterators report it. These services produce
// exactly those conditions.

// ── Gemini: non-2xx rejection — port 8097 ──────────────────────────────────
// The streaming POST binds to `http:Response`, which switches off the client's own
// status-code error mapping, so a rejected request has to be caught explicitly.
service /llm/vertexai on new http:Listener(8097) {
    resource function post v1/projects/[string projectId]/locations/[string location]/publishers/google/models/[string modelId](
            @http:Payload json _payload) returns http:Response|error {
        http:Response response = new;
        response.statusCode = 429;
        response.setJsonPayload({
            "error": {
                "code": 429,
                "message": "Quota exceeded for aiplatform.googleapis.com/generate_content_requests",
                "status": "RESOURCE_EXHAUSTED"
            }
        });
        return response;
    }
}

// ── Gemini: error frame mid-stream — port 8098 ─────────────────────────────
// Vertex emits `{"error": {...}}` in-band when a generation is cut short. It parses
// cleanly into the open `VertexAiResponse` record, so it has to be detected explicitly.
final json GEMINI_MIDSTREAM_ERROR = {
    "error": {"code": 429, "message": "Resource exhausted mid-generation", "status": "RESOURCE_EXHAUSTED"}
};

service /llm/vertexai on new http:Listener(8098) {
    resource function post v1/projects/[string projectId]/locations/[string location]/publishers/google/models/[string modelId](
            @http:Payload json _payload) returns stream<http:SseEvent, error?> {
        return toSseStream([
            GEMINI_TEXT_CHUNK_1.toJsonString(),
            GEMINI_MIDSTREAM_ERROR.toJsonString()
        ]);
    }
}

// ── Gemini: malformed frame mid-stream — port 8099 ─────────────────────────
service /llm/vertexai on new http:Listener(8099) {
    resource function post v1/projects/[string projectId]/locations/[string location]/publishers/google/models/[string modelId](
            @http:Payload json _payload) returns stream<http:SseEvent, error?> {
        return toSseStream([GEMINI_TEXT_CHUNK_1.toJsonString(), "{not-json"]);
    }
}

// ── Gemini: two function calls in separate events — port 8100 ──────────────
// `ai:ToolCallChunk.index` identifies one call across the whole stream, so these two
// calls must not both arrive as index 0 - a consumer accumulating by index would
// concatenate their arguments into invalid JSON.
final json GEMINI_PARALLEL_TOOL_CHUNK_1 = {
    "candidates": [{
        "content": {"role": "model", "parts": [{"functionCall": {"name": "get_weather", "args": {"city": "Colombo"}}}]},
        "index": 0
    }],
    "responseId": "gemini-stream-parallel"
};
final json GEMINI_PARALLEL_TOOL_CHUNK_2 = {
    "candidates": [{
        "content": {"role": "model", "parts": [{"functionCall": {"name": "get_weather", "args": {"city": "Kandy"}}}]},
        "finishReason": "STOP",
        "index": 0
    }],
    "responseId": "gemini-stream-parallel"
};

service /llm/vertexai on new http:Listener(8100) {
    resource function post v1/projects/[string projectId]/locations/[string location]/publishers/google/models/[string modelId](
            @http:Payload json _payload) returns stream<http:SseEvent, error?> {
        return toSseStream([
            GEMINI_PARALLEL_TOOL_CHUNK_1.toJsonString(),
            GEMINI_PARALLEL_TOOL_CHUNK_2.toJsonString()
        ]);
    }
}

// ── Anthropic: error event mid-stream — port 8101 ──────────────────────────
// The event's `type` is what separates a retryable overload from a terminal bad request,
// so it has to reach the caller alongside the message.
final json ANTH_ERROR_EVENT = {
    "type": "error",
    "error": {"type": "overloaded_error", "message": "Overloaded"}
};

service /llm/vertexai on new http:Listener(8101) {
    resource function post v1/projects/[string projectId]/locations/[string location]/publishers/anthropic/models/[string modelId](
            @http:Payload json _payload) returns stream<http:SseEvent, error?> {
        return toSseStream([
            ANTH_TEXT_MSG_START.toJsonString(),
            ANTH_TEXT_DELTA_1.toJsonString(),
            ANTH_ERROR_EVENT.toJsonString()
        ]);
    }
}

// ── Open models: usage-only final chunk — port 8102 ────────────────────────
// With `stream_options: { include_usage: true }` the final chunk carries usage and an
// empty `choices` array, and reports `total_tokens` alongside the two halves.
final json OPEN_MODEL_USAGE_ONLY_CHUNK = {
    "id": "chatcmpl-open-usage",
    "choices": [],
    "usage": {"prompt_tokens": 4, "completion_tokens": 6, "total_tokens": 10}
};

service /llm/vertexai on new http:Listener(8102) {
    resource function post v1beta1/projects/[string projectId]/locations/[string location]/endpoints/openapi/chat/completions(
            @http:Payload json payload) returns stream<http:SseEvent, error?> {
        assertUsageOptIn(payload);
        return toSseStream([
            OPEN_MODEL_TEXT_CHUNK_1.toJsonString(),
            OPEN_MODEL_TEXT_CHUNK_2.toJsonString(),
            OPEN_MODEL_TEXT_CHUNK_FINAL.toJsonString(),
            OPEN_MODEL_USAGE_ONLY_CHUNK.toJsonString(),
            "[DONE]"
        ]);
    }
}
