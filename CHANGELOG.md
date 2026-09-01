# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `ModelProvider` client class implementing `ai:ModelProvider` interface for LLM chat and structured content generation via Google Vertex AI, supporting Google Gemini models and partner models (Anthropic Claude, Mistral, Meta Llama, DeepSeek, Qwen, Kimi, MiniMax) through Vertex AI Model Garden.
- `EmbeddingProvider` client class implementing `ai:EmbeddingProvider` interface for vector embedding generation via Vertex AI embedding models.
- `ModelProvider.chatStream()` for streaming chat completions, routing to each publisher's streaming endpoint (Gemini `:streamGenerateContent`, Anthropic and Mistral `:streamRawPredict`, and the OpenAI-compatible open-models endpoint) and normalizing every native event format onto `ai:ChatCompletionChunk`.
- `ModelProvider.generateStream()` for streaming generated text, supporting `string` as the expected type.

### Changed
- Increased the default `maxTokens` for `ModelProvider` from 512 to 4096.

[Unreleased]: https://github.com/ballerina-platform/module-ballerinax-ai.googleapis.vertex/compare/v1.0.0...HEAD
