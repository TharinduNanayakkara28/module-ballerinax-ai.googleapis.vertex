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
import ballerina/ai.observe;
import ballerina/constraint;
import ballerina/http;
import ballerina/lang.array;

type ResponseSchema record {|
    map<json> schema;
    boolean isOriginallyJsonObject = true;
|};

const JSON_CONVERSION_ERROR = "FromJsonStringError";
const CONVERSION_ERROR = "ConversionError";
const ERROR_MESSAGE = "Error occurred while attempting to parse the response from the " +
    "LLM as the expected type. Retrying and/or validating the prompt could fix the response.";
const RESULT = "result";
const GET_RESULTS_TOOL = "getResults";
const NO_RELEVANT_RESPONSE_FROM_THE_LLM = "No relevant response from the LLM";

// ── URL helpers ───────────────────────────────────────────────────────────────

isolated function buildGenerateContentPath(string projectId, string location,
        string modelType, string publisher) returns string {
    // Google Gemini → :generateContent
    // Anthropic / Mistral on Vertex → :rawPredict
    string suffix = publisher == ANTHROPIC || publisher == MISTRAL
        ? ":rawPredict" : ":generateContent";
    return string `/v1/projects/${projectId}/locations/${location}/publishers/${publisher}/models/${modelType}${suffix}`;
}


isolated function buildOpenModelsPath(string projectId, string location) returns string {
    return string `/v1beta1/projects/${projectId}/locations/${location}/endpoints/openapi/chat/completions`;
}

isolated function buildStreamPath(string projectId, string location,
        string modelType, string publisher) returns string {
    // Google Gemini → :streamGenerateContent (needs ?alt=sse, added by the caller)
    // Anthropic / Mistral on Vertex → :streamRawPredict
    string suffix = publisher == ANTHROPIC || publisher == MISTRAL
        ? ":streamRawPredict" : ":streamGenerateContent";
    return string `/v1/projects/${projectId}/locations/${location}/publishers/${publisher}/models/${modelType}${suffix}`;
}

# Returns true when the publisher routes to the OpenAI-compatible open-models endpoint.
# Covers Meta, DeepSeek, Qwen, Kimi, and MiniMax hosted on Vertex AI Model Garden.
isolated function isOpenModelPublisher(string publisher) returns boolean {
    return publisher == META || publisher == DEEPSEEK_AI ||
        publisher == QWEN || publisher == KIMI || publisher == MINIMAX || publisher == OPENAI;
}

isolated function buildEmbedContentPath(string projectId, string location, string modelType) returns string {
    return string `/v1/projects/${projectId}/locations/${location}/publishers/google/models/${modelType}:predict`;
}

// ── Message conversion ────────────────────────────────────────────────────────

# Converts standard ai:ChatMessage types to Vertex AI content objects.
# Returns a tuple of [contentArray, systemInstruction?].
# System messages are accumulated and placed in the top-level systemInstruction field.
# Multiple system messages have their text parts merged into a single instruction.
isolated function convertMessagesToVertexAiContents(ai:ChatMessage[]|ai:ChatUserMessage messages)
        returns [VertexAiContent[], VertexAiSystemInstruction?]|ai:Error {
    VertexAiContent[] contents = [];
    VertexAiPart[] systemParts = [];

    if messages is ai:ChatUserMessage {
        string text = check getChatMessageStringContent(messages.content);
        contents.push({role: "user", parts: [{text}]});
        return [contents, ()];
    }

    foreach ai:ChatMessage message in messages {
        if message is ai:ChatSystemMessage {
            // Vertex AI system instructions go into the top-level systemInstruction field.
            // Accumulate parts from all system messages into a single instruction block.
            string text = check getChatMessageStringContent(message.content);
            systemParts.push({text});
        } else if message is ai:ChatUserMessage {
            string text = check getChatMessageStringContent(message.content);
            contents.push({role: "user", parts: [{text}]});
        } else if message is ai:ChatAssistantMessage {
            VertexAiContent assistantContent = check buildVertexAiAssistantContent(message);
            contents.push(assistantContent);
        } else if message is ai:ChatFunctionMessage {
            // Function results go into a user-role message with functionResponse parts
            map<json> responseBody = {};
            string? msgContent = message.content;
            if msgContent is string {
                // Wrap plain string content in a map<json> for functionResponse
                responseBody["output"] = msgContent;
            }
            VertexAiContent functionResponseContent = {
                role: "user",
                parts: [{
                    functionResponse: {
                        name: message.name,
                        response: responseBody
                    }
                }]
            };
            contents.push(functionResponseContent);
        }
    }

    VertexAiSystemInstruction? systemInstruction = systemParts.length() > 0 ? {parts: systemParts} : ();
    return [contents, systemInstruction];
}

isolated function buildVertexAiAssistantContent(ai:ChatAssistantMessage message)
        returns VertexAiContent|ai:Error {
    VertexAiPart[] parts = [];

    ai:FunctionCall[]? toolCalls = message.toolCalls;
    if toolCalls is ai:FunctionCall[] && toolCalls.length() > 0 {
        foreach ai:FunctionCall toolCall in toolCalls {
            parts.push({
                functionCall: {
                    name: toolCall.name,
                    args: toolCall.arguments ?: {}
                }
            });
        }
    }

    string? content = message.content;
    if content is string && content.length() > 0 {
        parts.push({text: content});
    }

    if parts.length() == 0 {
        return error ai:Error("Assistant message has neither content nor tool calls");
    }

    return {role: "model", parts};
}

// ── Response parsing ──────────────────────────────────────────────────────────

# Describes an empty Vertex AI candidate, folding in the `finishReason` when the model
# supplied one. A part-less candidate almost always means the generation was cut short
# (`MAX_TOKENS`) or filtered (`SAFETY`, `PROHIBITED_CONTENT`), and that reason is the only
# thing that tells the caller which it was.
#
# + candidate - The candidate that carried no usable content
# + return - The error message to report
isolated function buildEmptyCandidateMessage(VertexAiCandidate candidate) returns string {
    string? finishReason = candidate.finishReason;
    if finishReason is string {
        return string `Empty response from the Vertex AI model (finishReason: ${finishReason})`;
    }
    return "Empty response from the Vertex AI model";
}

# Builds an ai:ChatAssistantMessage from the Vertex AI response.
isolated function buildChatAssistantMessage(VertexAiResponse response) returns ai:ChatAssistantMessage|ai:Error {
    VertexAiCandidate[]? candidates = response.candidates;
    if candidates is () || candidates.length() == 0 {
        return error ai:LlmInvalidResponseError("Empty response from the Vertex AI model");
    }

    VertexAiCandidate candidate = candidates[0];
    VertexAiContent? candidateContent = candidate.content;
    if candidateContent is () {
        return error ai:LlmInvalidResponseError(buildEmptyCandidateMessage(candidate));
    }
    // A candidate can come back with no `parts` at all - observed on gemini-2.5-flash-lite
    // when the candidate is empty or filtered. That is a failed generation, not an empty
    // answer, and `generate()` already reports it as one; reporting it here too keeps
    // `chat()` from handing back a silently blank assistant message.
    VertexAiPart[]? candidateParts = candidateContent.parts;
    if candidateParts is () || candidateParts.length() == 0 {
        return error ai:LlmInvalidResponseError(buildEmptyCandidateMessage(candidate));
    }
    VertexAiPart[] parts = candidateParts;

    ai:FunctionCall[] functionCalls = [];
    string textAccumulator = "";

    foreach VertexAiPart part in parts {
        string? text = part.text;
        if text is string {
            textAccumulator += text;
        }
        VertexAiFunctionCall? functionCall = part.functionCall;
        if functionCall is VertexAiFunctionCall {
            functionCalls.push({
                name: functionCall.name,
                arguments: functionCall.args ?: {}
            });
        }
    }
    string? textContent = textAccumulator.length() > 0 ? textAccumulator : ();

    return {
        role: ai:ASSISTANT,
        content: textContent,
        toolCalls: functionCalls.length() > 0 ? functionCalls : ()
    };
}

// ── Tool helpers ──────────────────────────────────────────────────────────────

# Maps ai:ChatCompletionFunctions to Vertex AI tool format.
isolated function mapToVertexAiTools(ai:ChatCompletionFunctions[] tools) returns VertexAiTool[] {
    VertexAiFunctionDeclaration[] declarations = tools.map(t => <VertexAiFunctionDeclaration>{
        name: t.name,
        description: t.description,
        parameters: t.parameters
    });
    return [{functionDeclarations: declarations}];
}

# Builds a single-tool array containing the "getResults" tool with the given schema.
isolated function getGetResultsTool(map<json> parameters) returns VertexAiTool {
    return {
        functionDeclarations: [{
            name: GET_RESULTS_TOOL,
            description: "Tool to call with the response from a large language model (LLM) for a user prompt.",
            parameters
        }]
    };
}

# Builds a VertexAiToolConfig that forces calling the "getResults" tool.
isolated function getGetResultsToolConfig() returns VertexAiToolConfig {
    return {
        functionCallingConfig: {
            mode: "ANY",
            allowedFunctionNames: [GET_RESULTS_TOOL]
        }
    };
}

// ── Schema helpers ────────────────────────────────────────────────────────────

isolated function generateJsonObjectSchema(map<json> schema) returns ResponseSchema {
    string[] supportedMetaDataFields = ["$schema", "$id", "$anchor", "$comment", "title", "description"];

    if schema["type"] == "object" {
        return {schema};
    }

    map<json> updatedSchema = map from var [key, value] in schema.entries()
        where supportedMetaDataFields.indexOf(key) is int
        select [key, value];

    updatedSchema["type"] = "object";
    map<json> content = map from var [key, value] in schema.entries()
        where supportedMetaDataFields.indexOf(key) !is int
        select [key, value];

    updatedSchema["properties"] = {[RESULT]: content};

    return {schema: updatedSchema, isOriginallyJsonObject: false};
}

isolated function getExpectedResponseSchema(typedesc<anydata> expectedResponseTypedesc) returns ResponseSchema|ai:Error {
    typedesc<json>|error td = expectedResponseTypedesc.ensureType();
    if td is error {
        return error ai:Error("Unsupported return type for generate(): type must be a subtype of json", td);
    }
    return generateJsonObjectSchema(check generateJsonSchemaForTypedescAsJson(td));
}

// ── generate() orchestration ──────────────────────────────────────────────────

# Core function called from Generator.java via the Ballerina runtime to implement generate().
# Dispatches to the correct publisher-specific request format, forces the "getResults" tool
# call to get structured output, extracts the arguments, and deserialises them as the
# expected type.
isolated function generateLlmResponse(http:Client vertexAiClient, string accessToken,
        string modelType, string projectId, string location, string publisher,
        int maxTokens, decimal? temperature,
        ai:Prompt prompt, typedesc<json> expectedResponseTypedesc) returns anydata|ai:Error {
    observe:GenerateContentSpan span = observe:createGenerateContentSpan(modelType);
    span.addProvider(publisher);

    VertexAiPart[] contentParts;
    ResponseSchema responseSchema;
    do {
        contentParts = check buildContentPartsFromPrompt(prompt);
        responseSchema = check getExpectedResponseSchema(expectedResponseTypedesc);
    } on fail ai:Error err {
        span.close(err);
        return err;
    }

    string path = buildGenerateContentPath(projectId, location, modelType, publisher);
    map<string> headers = {
        "Authorization": string `Bearer ${accessToken}`,
        "Content-Type": "application/json"
    };

    map<json> arguments;

    if isOpenModelPublisher(publisher) {
        path = buildOpenModelsPath(projectId, location);
    }

    string promptText = "";
    foreach VertexAiPart p in contentParts {
        if p.text is string {
            promptText += <string>p.text;
        }
    }

    if publisher == ANTHROPIC {
        AnthropicTool resultTool = getAnthropicGetResultsTool(responseSchema.schema);
        AnthropicToolChoice toolChoice = getAnthropicGetResultsToolChoice();
        map<json> requestPayload = buildAnthropicPayload(
            [{role: "user", content: promptText}],
            (), [resultTool], toolChoice, maxTokens, temperature, ());
        span.addInputMessages(requestPayload["messages"]);

        AnthropicResponse|error response = vertexAiClient->post(path, requestPayload, headers);
        if response is error {
            ai:Error err = buildHttpError(response);
            span.close(err);
            return err;
        }
        span.addResponseId(response.id ?: "");
        span.addInputTokenCount(response.usage?.input_tokens ?: 0);
        span.addOutputTokenCount(response.usage?.output_tokens ?: 0);

        map<json>|ai:Error extractedArgs = extractAnthropicGetResultsArgs(response);
        if extractedArgs is ai:Error {
            span.close(extractedArgs);
            return extractedArgs;
        }
        arguments = extractedArgs;

    } else if publisher == MISTRAL {
        MistralTool resultTool = getMistralGetResultsTool(responseSchema.schema);
        MistralMessage userMessage = {role: "user", content: promptText};
        map<json> requestPayload = buildMistralPayload(
            string `${publisher}/${modelType}`, [userMessage], [resultTool], "any", maxTokens, temperature, ());
        span.addInputMessages(requestPayload["messages"]);

        MistralResponse|error response = vertexAiClient->post(path, requestPayload, headers);
        if response is error {
            ai:Error err = buildHttpError(response);
            span.close(err);
            return err;
        }
        span.addResponseId(response.id ?: "");
        span.addInputTokenCount(response.usage?.prompt_tokens ?: 0);
        span.addOutputTokenCount(response.usage?.completion_tokens ?: 0);

        map<json>|ai:Error extractedArgs = extractMistralGetResultsArgs(response);
        if extractedArgs is ai:Error {
            span.close(extractedArgs);
            return extractedArgs;
        }
        arguments = extractedArgs;

    } else if isOpenModelPublisher(publisher) {
        // Open models (Meta, DeepSeek, Qwen, Kimi, MiniMax, OpenAI) — OpenAI-compatible endpoint.
        // Forced tool calling is not supported on these models, so structured output is obtained
        // via a system prompt instructing the model to respond with JSON matching the schema.
        string modelId = string `${publisher}/${modelType}`;
        string schemaJson = responseSchema.schema.toJsonString();
        MistralMessage systemMessage = {
            role: "system",
            content: string `You must respond ONLY with a valid JSON object that strictly matches this JSON schema: ${schemaJson}. Do not include any explanation or text outside the JSON object.`
        };
        MistralMessage userMessage = {role: "user", content: promptText};
        map<json> requestPayload = buildMistralPayload(
            modelId, [systemMessage, userMessage], [], (), maxTokens, temperature, ());
        span.addInputMessages(requestPayload["messages"]);

        MistralResponse|error response = vertexAiClient->post(path, requestPayload, headers);
        if response is error {
            ai:Error err = buildHttpError(response);
            span.close(err);
            return err;
        }
        span.addResponseId(response.id ?: "");
        span.addInputTokenCount(response.usage?.prompt_tokens ?: 0);
        span.addOutputTokenCount(response.usage?.completion_tokens ?: 0);

        map<json>|ai:Error extractedArgs2 = extractOpenModelTextAsJson(response);
        if extractedArgs2 is ai:Error {
            span.close(extractedArgs2);
            return extractedArgs2;
        }
        arguments = extractedArgs2;

    } else {
        // Google Gemini path
        VertexAiTool resultTool = getGetResultsTool(responseSchema.schema);
        VertexAiToolConfig toolConfig = getGetResultsToolConfig();
        VertexAiGenerationConfig generationConfig = {maxOutputTokens: maxTokens};
        if temperature is decimal {
            generationConfig.temperature = temperature;
        }
        map<json> requestPayload = {
            "contents": [{"role": "user", "parts": contentParts.toJson()}],
            "tools": [resultTool.toJson()],
            "toolConfig": toolConfig.toJson(),
            "generationConfig": generationConfig.toJson()
        };
        span.addInputMessages(requestPayload["contents"]);

        VertexAiResponse|error response = vertexAiClient->post(path, requestPayload, headers);
        if response is error {
            ai:Error err = buildHttpError(response);
            span.close(err);
            return err;
        }
        span.addResponseId(response.responseId ?: "");
        span.addInputTokenCount(response.usageMetadata?.promptTokenCount ?: 0);
        span.addOutputTokenCount(response.usageMetadata?.candidatesTokenCount ?: 0);

        VertexAiFunctionCall? functionCallResult = ();
        VertexAiCandidate[]? candidates = response.candidates;
        if candidates is VertexAiCandidate[] && candidates.length() > 0 {
            VertexAiContent? responseContent = candidates[0].content;
            if responseContent is VertexAiContent {
                foreach VertexAiPart part in responseContent.parts ?: [] {
                    VertexAiFunctionCall? fc = part.functionCall;
                    if fc is VertexAiFunctionCall && fc.name == GET_RESULTS_TOOL {
                        functionCallResult = fc;
                        break;
                    }
                }
            }
        }

        if functionCallResult is () {
            ai:Error err = error ai:LlmInvalidResponseError(NO_RELEVANT_RESPONSE_FROM_THE_LLM);
            span.close(err);
            return err;
        }
        arguments = functionCallResult.args ?: {};
    }

    anydata|error res = parseResponseAsType(arguments.toJsonString(), expectedResponseTypedesc,
            responseSchema.isOriginallyJsonObject);
    if res is error {
        ai:Error err = error ai:LlmInvalidGenerationError(string `Invalid value returned from the LLM Client, expected: '${
            expectedResponseTypedesc.toBalString()}', found '${res.toBalString()}'`);
        span.close(err);
        return err;
    }

    anydata|error result = res.ensureType(expectedResponseTypedesc);
    if result is error {
        ai:Error err = error ai:LlmInvalidGenerationError(string `Invalid value returned from the LLM Client, expected: '${
            expectedResponseTypedesc.toBalString()}', found '${(typeof res).toBalString()}'`);
        span.close(err);
        return err;
    }

    span.addOutputMessages(result.toJson());
    span.addOutputType(observe:JSON);
    span.close();
    return result;
}

isolated function extractOpenModelTextAsJson(MistralResponse response) returns map<json>|ai:Error {
    if response.choices.length() == 0 {
        return error ai:LlmInvalidResponseError(NO_RELEVANT_RESPONSE_FROM_THE_LLM);
    }
    string? content = response.choices[0].message?.content;
    if content is () || content.trim() == "" {
        return error ai:LlmInvalidResponseError(NO_RELEVANT_RESPONSE_FROM_THE_LLM);
    }
    string text = content.trim();
    // Strip markdown code fences (e.g. ```json\n...\n```) that some models emit
    if text.startsWith("```") {
        int? newlineIdx = text.indexOf("\n");
        int? closingIdx = text.lastIndexOf("```");
        if newlineIdx is int && closingIdx is int && closingIdx > newlineIdx {
            text = text.substring(newlineIdx + 1, closingIdx).trim();
        }
    }
    map<json>|error parsed = text.fromJsonStringWithType();
    if parsed is error {
        return error ai:LlmInvalidResponseError(
            string `Failed to parse JSON from open model text response`, parsed);
    }
    return parsed;
}

isolated function parseResponseAsType(string resp,
        typedesc<anydata> expectedResponseTypedesc, boolean isOriginallyJsonObject) returns anydata|error {
    if !isOriginallyJsonObject {
        map<json> respContent = check resp.fromJsonStringWithType();
        anydata|error result = trap respContent[RESULT].fromJsonWithType(expectedResponseTypedesc);
        if result is error {
            return handleParseResponseError(result);
        }
        return result;
    }

    anydata|error result = resp.fromJsonStringWithType(expectedResponseTypedesc);
    if result is error {
        return handleParseResponseError(result);
    }
    return result;
}

isolated function handleParseResponseError(error chatResponseError) returns error {
    string msg = chatResponseError.message();
    if msg.includes(JSON_CONVERSION_ERROR) || msg.includes(CONVERSION_ERROR) {
        return error(string `${ERROR_MESSAGE}`, chatResponseError);
    }
    return chatResponseError;
}

// ── Prompt → content parts ────────────────────────────────────────────────────

isolated function buildContentPartsFromPrompt(ai:Prompt prompt) returns VertexAiPart[]|ai:Error {
    string[] & readonly strings = prompt.strings;
    anydata[] insertions = prompt.insertions;
    VertexAiPart[] parts = [];
    string accumulatedText = "";

    if strings.length() > 0 {
        accumulatedText += strings[0];
    }

    foreach int i in 0 ..< insertions.length() {
        anydata insertion = insertions[i];
        string nextStr = strings[i + 1];

        if insertion is ai:Document|ai:Chunk {
            addTextPart(accumulatedText, parts);
            accumulatedText = "";
            check addDocumentPart(insertion, parts);
        } else if insertion is (ai:Document|ai:Chunk)[] {
            addTextPart(accumulatedText, parts);
            accumulatedText = "";
            foreach ai:Document|ai:Chunk doc in insertion {
                check addDocumentPart(doc, parts);
            }
        } else {
            accumulatedText += insertion.toString();
        }
        accumulatedText += nextStr;
    }

    addTextPart(accumulatedText, parts);
    return parts;
}

isolated function addTextPart(string content, VertexAiPart[] parts) {
    if content.length() > 0 {
        parts.push({text: content});
    }
}

isolated function addDocumentPart(ai:Document|ai:Chunk doc, VertexAiPart[] parts) returns ai:Error? {
    if doc is ai:TextDocument|ai:TextChunk {
        addTextPart(doc.content, parts);
        return;
    }
    if doc is ai:ImageDocument {
        ai:Url|byte[] content = doc.content;
        if content is byte[] {
            string mimeType = doc.metadata?.mimeType ?: "image/*";
            string|error b64 = array:toBase64(content);
            if b64 is error {
                return error ai:Error("Failed to encode image: " + b64.message());
            }
            parts.push({inlineData: {mimeType, data: b64}});
        } else {
            // URL-based images: validate then pass inline as text reference (Vertex AI
            // supports file_data for GCS URIs; for HTTP URLs we embed as text for now)
            ai:Url|constraint:Error validationRes = constraint:validate(content);
            if validationRes is constraint:Error {
                return error ai:Error("Invalid image URL: " + validationRes.message(), validationRes);
            }
            parts.push({text: string `[Image: ${content}]`});
        }
        return;
    }
    return error ai:Error("Only text and image documents are supported.");
}

// ── Message conversion helper ─────────────────────────────────────────────────

isolated function getChatMessageStringContent(ai:Prompt|string prompt) returns string|ai:Error {
    if prompt is string {
        return prompt;
    }
    string[] & readonly strings = prompt.strings;
    anydata[] insertions = prompt.insertions;
    string promptStr = strings[0];
    foreach int i in 0 ..< insertions.length() {
        string str = strings[i + 1];
        anydata insertion = insertions[i];

        if insertion is ai:TextDocument|ai:TextChunk {
            promptStr += insertion.content + " " + str;
            continue;
        }

        if insertion is ai:TextDocument[] {
            foreach ai:TextDocument doc in insertion {
                promptStr += doc.content + " ";
            }
            promptStr += str;
            continue;
        }

        if insertion is ai:TextChunk[] {
            foreach ai:TextChunk doc in insertion {
                promptStr += doc.content + " ";
            }
            promptStr += str;
            continue;
        }

        if insertion is ai:Document {
            return error ai:Error("Only Text Documents are currently supported.");
        }

        promptStr += insertion.toString() + str;
    }
    return promptStr.trim();
}

isolated function convertMessageToJson(ai:ChatMessage[]|ai:ChatMessage messages) returns json|ai:Error {
    if messages is ai:ChatMessage[] {
        json[] result = [];
        foreach ai:ChatMessage msg in messages {
            result.push(check convertMessageToJson(msg));
        }
        return result;
    }
    if messages is ai:ChatUserMessage|ai:ChatSystemMessage {
        return {role: messages.role, content: check getChatMessageStringContent(messages.content), name: messages.name};
    }
    return messages;
}

// ── HTTP error helper ─────────────────────────────────────────────────────────

// ── generateStream() orchestration ──────────────────────────────────────────

# Builds the string stream behind the dependently-typed `generateStream`. The
# native `StreamGenerator` shim trampolines here so the type gating stays in
# Ballerina. Only `string` is supported; other types yield an error because a
# partial generation is a valid value only for `string`. When valid, the
# underlying `chatStream` chunks are projected onto their text fragments.
#
# + llmModel - The model provider whose `chatStream` supplies the chunks
# + prompt - The prompt to send to the model
# + td - The caller's expected type; must be `string`
# + return - A stream of text fragments, or an error if the type is unsupported
function generateLlmResponseStream(ModelProvider llmModel, ai:Prompt prompt, typedesc<anydata> td)
        returns stream<string, ai:Error?>|ai:Error {
    if td !is typedesc<string> {
        return error ai:Error("This data type is not supported for streaming. " +
            "'generateStream' supports only 'string'; use 'generate' for structured types.");
    }
    stream<ai:ChatCompletionChunk, ai:Error?> chunks = check llmModel->chatStream({role: ai:USER, content: prompt});
    stream<string, ai:Error?> textStream = new (new ChunkTextIterator(chunks));
    return textStream;
}

# Projects a normalized `ai:ChatCompletionChunk` stream onto its text content,
# yielding each non-empty `delta.content` fragment and skipping tool-call and
# usage-only chunks. Backs `generateLlmResponseStream`.
class ChunkTextIterator {
    private stream<ai:ChatCompletionChunk, ai:Error?> chunks;

    isolated function init(stream<ai:ChatCompletionChunk, ai:Error?> chunks) {
        self.chunks = chunks;
    }

    public isolated function next() returns record {|string value;|}|ai:Error? {
        while true {
            record {|ai:ChatCompletionChunk value;|}|ai:Error? next = self.chunks.next();
            if next is () {
                return ();
            }
            if next is ai:Error {
                return next;
            }
            ai:ChatCompletionChunkChoice[] choices = next.value.choices;
            if choices.length() == 0 {
                continue;
            }
            string? content = choices[0].delta.content;
            if content is string && content.length() > 0 {
                return {value: content};
            }
        }
    }

    public isolated function close() returns ai:Error? {
        return self.chunks.close();
    }
}

# Opens a Server-Sent Event stream against a Vertex AI streaming endpoint.
#
# The POST binds to `http:Response` because the payload has to be read as an event stream
# rather than data-bound, and that also switches off the client's status-code error
# mapping - so the status is checked here. Without it Vertex AI's own message for an
# expired token, a rate limit, a wrong model id, or a rejected parameter is discarded and
# the caller is told only that the stream could not be opened.
#
# + vertexAiClient - The HTTP client for the Vertex AI endpoint
# + path - The endpoint path to post to
# + payload - The request payload
# + headers - The request headers
# + return - The SSE event stream, or an `ai:Error` describing the failure
isolated function openSseStream(http:Client vertexAiClient, string path, map<json> payload,
        map<string> headers) returns stream<http:SseEvent, error?>|ai:Error {
    http:Response|error response = vertexAiClient->post(path, payload, headers);
    if response is error {
        return buildHttpError(response);
    }
    int statusCode = response.statusCode;
    if statusCode < 200 || statusCode >= 300 {
        string? detail = extractHttpErrorDetail(response);
        string message = detail is string
            ? string `Vertex AI rejected the streaming request with HTTP ${statusCode}: ${detail}`
            : string `Vertex AI rejected the streaming request with HTTP ${statusCode}`;
        return error ai:LlmConnectionError(message);
    }
    stream<http:SseEvent, error?>|error sseStream = response.getSseEventStream();
    if sseStream is error {
        return error ai:LlmConnectionError("Failed to open the SSE stream from the model", sseStream);
    }
    return sseStream;
}

# Pulls the human-readable detail out of a non-2xx streaming response, which carries the
# usual Vertex AI `{"error": {"message": ...}}` body rather than an event stream.
#
# + response - The non-2xx response
# + return - The failure detail, or `()` when the body carries none
isolated function extractHttpErrorDetail(http:Response response) returns string? {
    json|error payload = response.getJsonPayload();
    if payload is error {
        string|error text = response.getTextPayload();
        if text is string && text.trim() != "" {
            return text.trim();
        }
        return ();
    }
    string? frameMessage = extractStreamErrorFrame(payload);
    if frameMessage is string {
        return frameMessage;
    }
    return payload.toJsonString();
}

# Detects a Vertex AI `{"error": {...}}` frame in a streamed payload and returns its
# message. Vertex emits such a frame mid-stream when a generation is cut short (quota
# exhausted, token expiry, a safety abort), and it parses cleanly into the open wire
# records - so it has to be recognised explicitly rather than left to `cloneWithType`.
#
# + payload - The parsed SSE `data` payload
# + return - The error message, or `()` when the payload is not an error frame
isolated function extractStreamErrorFrame(json payload) returns string? {
    if payload !is map<json> {
        return ();
    }
    json? failure = payload["error"];
    if failure is () {
        return ();
    }
    if failure is map<json> {
        json? message = failure["message"];
        if message is string {
            return message;
        }
    }
    return failure.toJsonString();
}

isolated function buildHttpError(error httpError) returns ai:LlmConnectionError {
    if httpError is http:ApplicationResponseError {
        int statusCode = httpError.detail().statusCode;
        anydata body = httpError.detail().body;
        string bodyStr = body is string ? body : body.toBalString();
        return error ai:LlmConnectionError(
            string `Vertex AI API returned HTTP ${statusCode}: ${bodyStr}`, httpError);
    }
    return error ai:LlmConnectionError(
        string `Failed to connect to Vertex AI: ${httpError.message()}`, httpError);
}
