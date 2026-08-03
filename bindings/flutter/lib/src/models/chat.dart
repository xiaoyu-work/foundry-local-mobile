// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:convert';

import 'package:meta/meta.dart';

/// A tool the model may call. Mirrors the OpenAI tool shape.
@immutable
class ChatTool {
  const ChatTool({
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String name;
  final String description;

  /// JSON Schema describing the tool's arguments.
  final Map<String, Object?> parameters;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'description': description,
        'parameters': parameters,
      };
}

/// One part of a multi-modal user message.
@immutable
sealed class ContentPart {
  const ContentPart();
  Map<String, Object?> toJson();

  factory ContentPart.text(String text) => TextContent(text);
  factory ContentPart.imageFile(String path) => ImageContent(path: path);
  factory ContentPart.imageBase64(String data) =>
      ImageContent(dataBase64: data);
  factory ContentPart.audioFile(String path) => AudioContent(path: path);
  factory ContentPart.audioBase64(String data) =>
      AudioContent(dataBase64: data);
}

@immutable
class TextContent extends ContentPart {
  const TextContent(this.text);
  final String text;
  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'type': 'text',
        'text': text,
      };
}

@immutable
class ImageContent extends ContentPart {
  const ImageContent({this.path, this.dataBase64})
      : assert(path != null || dataBase64 != null,
            'Either path or dataBase64 must be provided.');
  final String? path;
  final String? dataBase64;
  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'type': 'image',
        if (path != null) 'path': path,
        if (dataBase64 != null) 'data_base64': dataBase64,
      };
}

@immutable
class AudioContent extends ContentPart {
  const AudioContent({this.path, this.dataBase64})
      : assert(path != null || dataBase64 != null,
            'Either path or dataBase64 must be provided.');
  final String? path;
  final String? dataBase64;
  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'type': 'audio',
        if (path != null) 'path': path,
        if (dataBase64 != null) 'data_base64': dataBase64,
      };
}

/// One entry in the chat request's `messages` array. The `content` field can
/// be either a plain string or a list of content parts.
@immutable
class ChatMessage {
  const ChatMessage.system(this.textContent)
      : role = 'system',
        parts = null;
  const ChatMessage.user(this.textContent)
      : role = 'user',
        parts = null;
  const ChatMessage.assistant(this.textContent)
      : role = 'assistant',
        parts = null;
  const ChatMessage.multipart({required this.role, required this.parts})
      : textContent = null;

  final String role;
  final String? textContent;
  final List<ContentPart>? parts;

  Map<String, Object?> toJson() {
    if (textContent != null) {
      return <String, Object?>{'role': role, 'content': textContent};
    }
    return <String, Object?>{
      'role': role,
      'content': parts!.map((p) => p.toJson()).toList(),
    };
  }
}

/// A chat completion request. Serialized to the OpenAI-shaped `request_json`
/// on `flm_session_complete_async`.
@immutable
class ChatRequest {
  const ChatRequest({
    required this.messages,
    this.tools = const <ChatTool>[],
    this.toolChoice,
    this.temperature,
    this.topP,
    this.topK,
    this.maxOutputTokens,
    this.seed,
  });

  final List<ChatMessage> messages;
  final List<ChatTool> tools;

  /// `auto`, `none`, `required`, or `{ "name": "toolName" }`.
  final Object? toolChoice;
  final double? temperature;
  final double? topP;
  final int? topK;
  final int? maxOutputTokens;
  final int? seed;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'messages': messages.map((m) => m.toJson()).toList(),
      if (tools.isNotEmpty) 'tools': tools.map((t) => t.toJson()).toList(),
      if (toolChoice != null) 'tool_choice': toolChoice,
      if (temperature != null) 'temperature': temperature,
      if (topP != null) 'top_p': topP,
      if (topK != null) 'top_k': topK,
      if (maxOutputTokens != null) 'max_output_tokens': maxOutputTokens,
      if (seed != null) 'seed': seed,
    };
  }

  String toJsonString() => jsonEncode(toJson());
}

/// A tool result submitted with [ChatSession.submitToolResults].
@immutable
class ToolResult {
  const ToolResult({required this.callId, required this.result});
  final String callId;

  /// Serialized result. May be a JSON string, plain text, or a JSON-encodable
  /// value that will be stringified before crossing the ABI.
  final Object result;

  Map<String, Object?> toJson() {
    final String encoded;
    if (result is String) {
      encoded = result as String;
    } else {
      encoded = jsonEncode(result);
    }
    return <String, Object?>{'call_id': callId, 'result': encoded};
  }
}

/// The full text of a non-streaming chat completion, plus the parsed tool
/// calls (if any) and usage counters. Read from `flm_job_take_result_json`.
@immutable
class ChatCompletion {
  const ChatCompletion({
    required this.text,
    required this.finishReason,
    required this.toolCalls,
    required this.promptTokens,
    required this.completionTokens,
    this.raw = const <String, Object?>{},
  });

  final String text;
  final String finishReason;
  final List<Map<String, Object?>> toolCalls;
  final int promptTokens;
  final int completionTokens;
  final Map<String, Object?> raw;

  factory ChatCompletion.fromJson(Map<String, Object?> json) {
    final usage = (json['usage'] as Map?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    return ChatCompletion(
      text: json['text'] as String? ?? '',
      finishReason: json['finish_reason'] as String? ?? 'stop',
      toolCalls: (json['tool_calls'] as List?)?.cast<Map<String, Object?>>() ??
          const <Map<String, Object?>>[],
      promptTokens: (usage['prompt_tokens'] as num?)?.toInt() ?? 0,
      completionTokens:
          (usage['completion_tokens'] as num?)?.toInt() ?? 0,
      raw: json,
    );
  }
}

/// Result of `flm_session_embed_async`.
@immutable
class EmbeddingResult {
  const EmbeddingResult({required this.embeddings, required this.dimensions});
  final List<List<double>> embeddings;
  final int dimensions;

  factory EmbeddingResult.fromJson(Map<String, Object?> json) {
    final rows = (json['embeddings'] as List?)
            ?.map((r) => (r as List).cast<num>().map((n) => n.toDouble()).toList())
            .toList(growable: false) ??
        const <List<double>>[];
    return EmbeddingResult(
      embeddings: rows,
      dimensions: (json['dimensions'] as num?)?.toInt() ??
          (rows.isNotEmpty ? rows.first.length : 0),
    );
  }
}

/// Result of `flm_session_transcribe_async` for the batch case.
@immutable
class TranscriptionResult {
  const TranscriptionResult({
    required this.text,
    required this.language,
    required this.segments,
    this.raw = const <String, Object?>{},
  });

  final String text;
  final String language;
  final List<Map<String, Object?>> segments;
  final Map<String, Object?> raw;

  factory TranscriptionResult.fromJson(Map<String, Object?> json) =>
      TranscriptionResult(
        text: json['text'] as String? ?? '',
        language: json['language'] as String? ?? '',
        segments: (json['segments'] as List?)?.cast<Map<String, Object?>>() ??
            const <Map<String, Object?>>[],
        raw: json,
      );
}
