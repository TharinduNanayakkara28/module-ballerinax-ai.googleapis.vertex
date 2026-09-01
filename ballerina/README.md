## Overview

This module offers APIs for connecting with models hosted on
[Google Vertex AI](https://cloud.google.com/vertex-ai), including Google Gemini models and partner
models from Anthropic, Mistral, Meta, DeepSeek, Qwen, Kimi, and MiniMax available through the
Vertex AI Model Garden.

## Prerequisites

Before using this module in your Ballerina application, you must have a Google Cloud project with
Vertex AI enabled.

- Create a [Google Cloud account](https://cloud.google.com) and set up a project.
- Enable the [Vertex AI API](https://console.cloud.google.com/apis/library/aiplatform.googleapis.com) for your project.
- Set up authentication using one of the supported methods below.

## Quickstart

To use the `ai.googleapis.vertex` module in your Ballerina application, update the `.bal` file as follows:

### Step 1: Import the module

Import the `ai.googleapis.vertex` module.

```ballerina
import ballerinax/ai.googleapis.vertex;
```

### Step 2: Initialize the Model Provider

Three authentication options are supported:

**Option 1 — OAuth2 refresh token** (recommended for development; credentials from `~/.config/gcloud/application_default_credentials.json`):

```ballerina
import ballerina/ai;
import ballerinax/ai.googleapis.vertex;

final ai:ModelProvider vertexModel = check new vertex:ModelProvider(
    auth = {
        clientId: "your-client-id",
        clientSecret: "your-client-secret",
        refreshToken: "your-refresh-token"
    },
    projectId = "your-gcp-project-id",
    location = "us-central1",
    model = "google/gemini-2.0-flash"
);
```

**Option 2 — Service account JSON key file** (recommended for production):

```ballerina
final ai:ModelProvider vertexModel = check new vertex:ModelProvider(
    auth = "/path/to/service-account-key.json",
    projectId = "your-gcp-project-id",
    location = "us-central1",
    model = "google/gemini-2.0-flash"
);
```

**Option 3 — Service account inline credentials** (use when you need to override scopes):

```ballerina
final ai:ModelProvider vertexModel = check new vertex:ModelProvider(
    auth = {
        clientEmail: "your-sa@your-project.iam.gserviceaccount.com",
        privateKey: "-----BEGIN RSA PRIVATE KEY-----\n..."
    },
    projectId = "your-gcp-project-id",
    location = "us-central1",
    model = "google/gemini-2.0-flash"
);
```

### Step 3: Invoke chat completion

```ballerina
ai:ChatMessage[] chatMessages = [{role: "user", content: "hi"}];
ai:ChatAssistantMessage response = check vertexModel->chat(chatMessages, tools = []);

chatMessages.push(response);
```

### Step 4: Generate typed output

```ballerina
type Sentiment record {|
    string label;
    decimal score;
|};

@ai:JsonSchema {
    "type": "object",
    "required": ["label", "score"],
    "properties": {
        "label": {"type": "string", "enum": ["positive", "neutral", "negative"]},
        "score": {"type": "number"}
    }
}
type SentimentType Sentiment;

Sentiment|error result = vertexModel->generate(
    `Analyze the sentiment of: "I love this product!"`
);
```

### Step 5: Stream a chat completion

`chatStream` returns the response incrementally, as normalized `ai:ChatCompletionChunk`
values. It works across every supported publisher - Gemini, Anthropic, Mistral, and the
open-models endpoint - each publisher's native event format is mapped onto the same shape.

```ballerina
stream<ai:ChatCompletionChunk, ai:Error?> chunks =
    check vertexModel->chatStream([{role: "user", content: "Write a haiku about Colombo"}]);

check from ai:ChatCompletionChunk chunk in chunks
    do {
        string? fragment = chunk.choices[0].delta.content;
        if fragment is string {
            io:print(fragment);
        }
    };
```

Closing the stream early releases the underlying HTTP connection:

```ballerina
check chunks.close();
```

### Step 6: Stream generated text

`generateStream` streams just the answer text, skipping tool-call and usage-only chunks.
Only `string` is supported - a partial generation is a valid value only for `string`, so
use `generate` for structured types.

```ballerina
stream<string, ai:Error?> fragments = check vertexModel->generateStream(`Explain SSE in one paragraph`);

check from string fragment in fragments
    do {
        io:print(fragment);
    };
```

### Step 7: Use an embedding provider

```ballerina
import ballerina/ai;
import ballerinax/ai.googleapis.vertex;

final ai:EmbeddingProvider vertexEmbedding = check new vertex:EmbeddingProvider(
    auth = "/path/to/service-account-key.json",
    projectId = "your-gcp-project-id",
    location = "us-central1"
);

ai:Embedding embedding = check vertexEmbedding->embed(<ai:TextChunk>{content: "Hello, world!"});
```
