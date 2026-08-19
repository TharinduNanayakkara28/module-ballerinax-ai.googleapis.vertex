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
import ballerina/test;

// ── Streaming test suite ────────────────────────────────────────────────────
// Exercises chatStream() and generateStream() against the mock SSE services in
// stream_test_services.bal, covering all four publisher wire formats this
// module supports: Gemini (native), Anthropic (Messages API events), Mistral
// (OpenAI-compatible chunks via rawPredict), and the shared open-models
// endpoint (OpenAI-compatible chunks, DeepSeek used as the representative
// publisher). Each publisher is checked for: incremental text streaming,
// finish-reason/usage mapping, tool-call id/name/argument-fragment streaming
// (accumulated by index, matching how a real agent loop would consume it),
// and the generateStream text projection.

const GEMINI_STREAM_TEXT_URL = "http://localhost:8090/llm/vertexai";
const GEMINI_STREAM_TOOL_URL = "http://localhost:8094/llm/vertexai";
const ANTHROPIC_STREAM_TEXT_URL = "http://localhost:8091/llm/vertexai";
const ANTHROPIC_STREAM_TOOL_URL = "http://localhost:8095/llm/vertexai";
const MISTRAL_STREAM_TEXT_URL = "http://localhost:8092/llm/vertexai";
const MISTRAL_STREAM_TOOL_URL = "http://localhost:8096/llm/vertexai";
const OPEN_MODEL_STREAM_TEXT_URL = "http://localhost:8093/llm/vertexai";

ModelProvider? geminiStreamTextProvider = ();
ModelProvider? geminiStreamToolProvider = ();
ModelProvider? anthropicStreamTextProvider = ();
ModelProvider? anthropicStreamToolProvider = ();
ModelProvider? mistralStreamTextProvider = ();
ModelProvider? mistralStreamToolProvider = ();
ModelProvider? openModelStreamTextProvider = ();

@test:BeforeSuite
function initStreamProviders() returns error? {
    geminiStreamTextProvider = check new (TEST_AUTH, PROJECT_ID, GEMINI_2_0_FLASH, LOCATION, GEMINI_STREAM_TEXT_URL);
    geminiStreamToolProvider = check new (TEST_AUTH, PROJECT_ID, GEMINI_2_0_FLASH, LOCATION, GEMINI_STREAM_TOOL_URL);
    anthropicStreamTextProvider =
        check new (TEST_AUTH, PROJECT_ID, "anthropic/claude-test-model", LOCATION, ANTHROPIC_STREAM_TEXT_URL);
    anthropicStreamToolProvider =
        check new (TEST_AUTH, PROJECT_ID, "anthropic/claude-test-model", LOCATION, ANTHROPIC_STREAM_TOOL_URL);
    mistralStreamTextProvider =
        check new (TEST_AUTH, PROJECT_ID, "mistralai/mistral-test-model", LOCATION, MISTRAL_STREAM_TEXT_URL);
    mistralStreamToolProvider =
        check new (TEST_AUTH, PROJECT_ID, "mistralai/mistral-test-model", LOCATION, MISTRAL_STREAM_TOOL_URL);
    openModelStreamTextProvider =
        check new (TEST_AUTH, PROJECT_ID, "deepseek-ai/deepseek-test-model", LOCATION, OPEN_MODEL_STREAM_TEXT_URL);
}

// ── Shared stream-collection helpers ────────────────────────────────────────

type AccumulatedToolCall record {|
    string id = "";
    string name = "";
    string args = "";
|};

type StreamResult record {|
    string text = "";
    int chunkCount = 0;
    ai:FinishReason? finishReason = ();
    ai:CompletionTokenUsage? usage = ();
    map<AccumulatedToolCall> toolCalls = {};
|};

final ai:ChatCompletionFunctions WEATHER_TOOL = {
    name: "get_weather",
    description: "Get the current weather for a given city.",
    parameters: {
        "type": "object",
        "properties": {"city": {"type": "string", "description": "The city name, e.g. Colombo"}},
        "required": ["city"]
    }
};

isolated function collectStream(stream<ai:ChatCompletionChunk, ai:Error?> chunks) returns StreamResult|ai:Error {
    StreamResult result = {};
    check from ai:ChatCompletionChunk chunk in chunks
        do {
            result.chunkCount += 1;
            if chunk.choices.length() > 0 {
                ai:ChatCompletionChunkChoice choice = chunk.choices[0];
                string? fragment = choice.delta.content;
                if fragment is string {
                    result.text += fragment;
                }
                ai:FinishReason? reason = choice.finishReason;
                if reason is ai:FinishReason {
                    result.finishReason = reason;
                }
                ai:ToolCallChunk[]? toolCallChunks = choice.delta.toolCalls;
                if toolCallChunks is ai:ToolCallChunk[] {
                    foreach ai:ToolCallChunk tc in toolCallChunks {
                        string key = tc.index.toString();
                        AccumulatedToolCall acc = result.toolCalls[key] ?: {};
                        string? id = tc?.id;
                        if id is string {
                            acc.id = id;
                        }
                        ai:FunctionCallChunk? fn = tc?.'function;
                        if fn is ai:FunctionCallChunk {
                            string? name = fn?.name;
                            if name is string {
                                acc.name = name;
                            }
                            string? args = fn?.arguments;
                            if args is string {
                                acc.args += args;
                            }
                        }
                        result.toolCalls[key] = acc;
                    }
                }
            }
            ai:CompletionTokenUsage? u = chunk.usage;
            if u is ai:CompletionTokenUsage {
                result.usage = u;
            }
        };
    return result;
}

isolated function collectText(stream<string, ai:Error?> fragments) returns string|ai:Error {
    string text = "";
    check from string fragment in fragments
        do {
            text += fragment;
        };
    return text;
}

// ── Gemini ───────────────────────────────────────────────────────────────────

@test:Config
function testGeminiChatStreamText() returns error? {
    ModelProvider p = <ModelProvider>geminiStreamTextProvider;
    stream<ai:ChatCompletionChunk, ai:Error?> chunks = check p->chatStream([{role: ai:USER, content: "Say hello"}]);
    StreamResult result = check collectStream(chunks);

    test:assertEquals(result.text, "Hello, world!");
    test:assertEquals(result.finishReason, ai:STOP);
    test:assertEquals(result.usage, {promptTokens: 5, completionTokens: 10, totalTokens: 15});
    test:assertTrue(result.chunkCount >= 3, "expected multiple incremental chunks");
}

@test:Config
function testGeminiChatStreamToolCall() returns error? {
    ModelProvider p = <ModelProvider>geminiStreamToolProvider;
    stream<ai:ChatCompletionChunk, ai:Error?> chunks = check p->chatStream(
        [{role: ai:USER, content: "What is the weather in Colombo?"}], [WEATHER_TOOL]);
    StreamResult result = check collectStream(chunks);

    test:assertEquals(result.finishReason, ai:TOOL_CALLS);
    AccumulatedToolCall acc = check getToolCall(result, "0");
    test:assertEquals(acc.name, "get_weather");
    test:assertEquals(check parseArgs(acc.args), {"city": "Colombo"});
}

@test:Config
function testGeminiGenerateStream() returns error? {
    ModelProvider p = <ModelProvider>geminiStreamTextProvider;
    stream<string, ai:Error?> fragments = check p->generateStream(`Say hello`);
    test:assertEquals(check collectText(fragments), "Hello, world!");
}

// ── Anthropic ────────────────────────────────────────────────────────────────

@test:Config
function testAnthropicChatStreamText() returns error? {
    ModelProvider p = <ModelProvider>anthropicStreamTextProvider;
    stream<ai:ChatCompletionChunk, ai:Error?> chunks = check p->chatStream([{role: ai:USER, content: "Say hello"}]);
    StreamResult result = check collectStream(chunks);

    test:assertEquals(result.text, "Hello, world!");
    test:assertEquals(result.finishReason, ai:STOP);
    test:assertEquals(result.usage, {promptTokens: 10, completionTokens: 8, totalTokens: 18});
}

@test:Config
function testAnthropicChatStreamToolCall() returns error? {
    ModelProvider p = <ModelProvider>anthropicStreamToolProvider;
    stream<ai:ChatCompletionChunk, ai:Error?> chunks = check p->chatStream(
        [{role: ai:USER, content: "What is the weather in Colombo?"}], [WEATHER_TOOL]);
    StreamResult result = check collectStream(chunks);

    test:assertEquals(result.finishReason, ai:TOOL_CALLS);
    test:assertEquals(result.usage, {promptTokens: 15, completionTokens: 12, totalTokens: 27});
    AccumulatedToolCall acc = check getToolCall(result, "0");
    test:assertEquals(acc.id, "toolu_1");
    test:assertEquals(acc.name, "get_weather");
    test:assertEquals(check parseArgs(acc.args), {"city": "Colombo"});
}

@test:Config
function testAnthropicGenerateStream() returns error? {
    ModelProvider p = <ModelProvider>anthropicStreamTextProvider;
    stream<string, ai:Error?> fragments = check p->generateStream(`Say hello`);
    test:assertEquals(check collectText(fragments), "Hello, world!");
}

// ── Mistral ──────────────────────────────────────────────────────────────────

@test:Config
function testMistralChatStreamText() returns error? {
    ModelProvider p = <ModelProvider>mistralStreamTextProvider;
    stream<ai:ChatCompletionChunk, ai:Error?> chunks = check p->chatStream([{role: ai:USER, content: "Say hello"}]);
    StreamResult result = check collectStream(chunks);

    test:assertEquals(result.text, "Hello, world!");
    test:assertEquals(result.finishReason, ai:STOP);
    test:assertEquals(result.usage, {promptTokens: 5, completionTokens: 10});
}

@test:Config
function testMistralChatStreamToolCall() returns error? {
    ModelProvider p = <ModelProvider>mistralStreamToolProvider;
    stream<ai:ChatCompletionChunk, ai:Error?> chunks = check p->chatStream(
        [{role: ai:USER, content: "What is the weather in Colombo?"}], [WEATHER_TOOL]);
    StreamResult result = check collectStream(chunks);

    test:assertEquals(result.finishReason, ai:TOOL_CALLS);
    AccumulatedToolCall acc = check getToolCall(result, "0");
    test:assertEquals(acc.id, "call_1");
    test:assertEquals(acc.name, "get_weather");
    test:assertEquals(check parseArgs(acc.args), {"city": "Colombo"});
}

@test:Config
function testMistralGenerateStream() returns error? {
    ModelProvider p = <ModelProvider>mistralStreamTextProvider;
    stream<string, ai:Error?> fragments = check p->generateStream(`Say hello`);
    test:assertEquals(check collectText(fragments), "Hello, world!");
}

// ── Open-model publishers (Meta/DeepSeek/Qwen/Kimi/MiniMax) ────────────────
// These share both the request path and toAiChunkOpenAiCompat mapping with
// Mistral (see stream_test_services.bal), so only the text scenario is
// covered separately here; tool-call argument streaming through that shared
// mapping is already verified by testMistralChatStreamToolCall above.

@test:Config
function testOpenModelChatStreamText() returns error? {
    ModelProvider p = <ModelProvider>openModelStreamTextProvider;
    stream<ai:ChatCompletionChunk, ai:Error?> chunks = check p->chatStream([{role: ai:USER, content: "Say hi"}]);
    StreamResult result = check collectStream(chunks);

    test:assertEquals(result.text, "Hi there!");
    test:assertEquals(result.finishReason, ai:STOP);
    test:assertEquals(result.usage, {promptTokens: 4, completionTokens: 6});
}

@test:Config
function testOpenModelGenerateStream() returns error? {
    ModelProvider p = <ModelProvider>openModelStreamTextProvider;
    stream<string, ai:Error?> fragments = check p->generateStream(`Say hi`);
    test:assertEquals(check collectText(fragments), "Hi there!");
}

// ── generateStream type-gating ──────────────────────────────────────────────

@test:Config
function testGenerateStreamRejectsNonStringType() {
    ModelProvider p = <ModelProvider>geminiStreamTextProvider;
    stream<int, ai:Error?>|ai:Error result = p->generateStream(`Give me a number`);
    test:assertTrue(result is ai:Error, "expected an error for a non-string generateStream type");
    if result is ai:Error {
        test:assertTrue(result.message().includes("only 'string'"), "unexpected error message: " + result.message());
    }
}

// ── Assertion helpers ────────────────────────────────────────────────────────

isolated function getToolCall(StreamResult result, string index) returns AccumulatedToolCall|error {
    AccumulatedToolCall? acc = result.toolCalls[index];
    if acc is () {
        test:assertFail(string `expected a streamed tool call at index ${index}`);
    }
    return acc;
}

isolated function parseArgs(string args) returns map<json>|error {
    return args.fromJsonStringWithType();
}
