// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:convert' show utf8;
import 'dart:ffi';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../bindings/bindings.dart' as raw;

/// Terminal reason for a completed generation.
enum FinishReason {
  none,
  stop,
  length,
  toolCalls,
  cancelled,
  error;

  static FinishReason fromCode(int code) {
    switch (code) {
      case raw.FlmFinishReason.stop:
        return FinishReason.stop;
      case raw.FlmFinishReason.length:
        return FinishReason.length;
      case raw.FlmFinishReason.toolCalls:
        return FinishReason.toolCalls;
      case raw.FlmFinishReason.cancelled:
        return FinishReason.cancelled;
      case raw.FlmFinishReason.error:
        return FinishReason.error;
      default:
        return FinishReason.none;
    }
  }
}

/// One event on a streaming session. Every subclass is a value type — the raw
/// C struct's borrowed strings are copied before construction, so a delta is
/// safe to hold across event-loop turns.
@immutable
sealed class SessionDelta {
  const SessionDelta();

  factory SessionDelta.fromNative(Pointer<raw.flm_delta> ptr) {
    final d = ptr.ref;
    switch (d.kind) {
      case raw.FlmDeltaKind.text:
        return TextDelta(_readUtf8(d.text, d.text_length));
      case raw.FlmDeltaKind.reasoning:
        return ReasoningDelta(_readUtf8(d.text, d.text_length));
      case raw.FlmDeltaKind.toolCall:
        return ToolCallDelta(
          id: _readCString(d.tool_call_id) ?? '',
          name: _readCString(d.tool_name) ?? '',
          argumentsJson: _readCString(d.tool_arguments_json) ?? '{}',
        );
      case raw.FlmDeltaKind.speechPartial:
        return SpeechDelta(
          text: _readUtf8(d.text, d.text_length),
          isFinal: false,
          startMs: d.start_time_ms,
          endMs: d.end_time_ms,
        );
      case raw.FlmDeltaKind.speechFinal:
        return SpeechDelta(
          text: _readUtf8(d.text, d.text_length),
          isFinal: true,
          startMs: d.start_time_ms,
          endMs: d.end_time_ms,
        );
      case raw.FlmDeltaKind.usage:
        return UsageDelta(
          promptTokens: d.prompt_tokens,
          completionTokens: d.completion_tokens,
        );
      case raw.FlmDeltaKind.completed:
        return CompletedDelta(
          finishReason: FinishReason.fromCode(d.finish_reason),
          promptTokens: d.prompt_tokens,
          completionTokens: d.completion_tokens,
        );
    }
    return TextDelta(_readUtf8(d.text, d.text_length));
  }
}

/// Assistant text fragment.
class TextDelta extends SessionDelta {
  const TextDelta(this.text);
  final String text;
}

/// Chain-of-thought fragment from a reasoning model.
class ReasoningDelta extends SessionDelta {
  const ReasoningDelta(this.text);
  final String text;
}

/// The model wants the host to execute a tool. Answer with
/// [ChatSession.submitToolResults].
@immutable
class ToolCallDelta extends SessionDelta {
  const ToolCallDelta({
    required this.id,
    required this.name,
    required this.argumentsJson,
  });

  final String id;
  final String name;

  /// Raw JSON string of tool arguments. Left un-parsed so the caller can drop
  /// it straight into their tool router without a round-trip through Dart maps.
  final String argumentsJson;
}

/// One speech-to-text hypothesis (or final segment).
@immutable
class SpeechDelta extends SessionDelta {
  const SpeechDelta({
    required this.text,
    required this.isFinal,
    required this.startMs,
    required this.endMs,
  });

  final String text;
  final bool isFinal;

  /// Offset of the segment relative to the start of the audio, in ms.
  final int startMs;
  final int endMs;

  Duration get start => Duration(milliseconds: startMs);
  Duration get end => Duration(milliseconds: endMs);
}

/// Token accounting update fired periodically during generation.
@immutable
class UsageDelta extends SessionDelta {
  const UsageDelta({
    required this.promptTokens,
    required this.completionTokens,
  });

  final int promptTokens;
  final int completionTokens;
}

/// Terminal event. Delivered exactly once at the end of a generation, unless
/// the call errors out before it starts.
@immutable
class CompletedDelta extends SessionDelta {
  const CompletedDelta({
    required this.finishReason,
    required this.promptTokens,
    required this.completionTokens,
  });

  final FinishReason finishReason;
  final int promptTokens;
  final int completionTokens;
}

// -----------------------------------------------------------------------------
// Helpers for reading borrowed C strings out of `flm_delta`. Keep private so
// they cannot be accidentally used on a pointer whose lifetime has already
// ended.
// -----------------------------------------------------------------------------

String _readUtf8(Pointer<Char> ptr, int length) {
  if (ptr == nullptr || length == 0) return '';
  // `flm_delta.text_length` counts bytes and permits embedded NULs.
  final bytes =
      ptr.cast<Uint8>().asTypedList(length, finalizer: null);
  // Copy because the underlying memory is borrowed.
  return utf8.decode(Uint8List.fromList(bytes));
}

String? _readCString(Pointer<Char> ptr) {
  if (ptr == nullptr) return null;
  var length = 0;
  final bytes = ptr.cast<Uint8>();
  while (bytes[length] != 0) {
    length++;
  }
  return utf8.decode(bytes.asTypedList(length));
}
