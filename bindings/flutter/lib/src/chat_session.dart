// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings/native_library.dart';
import 'error_capture.dart';
import 'job_runner.dart';
import 'model.dart';
import 'models/chat.dart';
import 'models/delta.dart';
import 'native_strings.dart';
import 'session_base.dart';

/// Options for a chat session. Mirrors the `type: chat` shape of the
/// `flm_session_create` options JSON.
class ChatSessionOptions {
  const ChatSessionOptions({
    this.systemPrompt,
    this.temperature,
    this.topP,
    this.topK,
    this.maxOutputTokens,
    this.seed,
    this.keepHistory = true,
  });

  final String? systemPrompt;
  final double? temperature;
  final double? topP;
  final int? topK;
  final int? maxOutputTokens;
  final int? seed;
  final bool keepHistory;

  Map<String, Object?> toJson() => <String, Object?>{
        'type': 'chat',
        if (systemPrompt != null) 'system_prompt': systemPrompt,
        if (temperature != null) 'temperature': temperature,
        if (topP != null) 'top_p': topP,
        if (topK != null) 'top_k': topK,
        if (maxOutputTokens != null) 'max_output_tokens': maxOutputTokens,
        if (seed != null) 'seed': seed,
        'keep_history': keepHistory,
      };
}

/// A stateful chat session.
class ChatSession extends Session {
  ChatSession._(Model model, int handle) : super(model: model, handle: handle);

  factory ChatSession.create(Model model, ChatSessionOptions options) =>
      ChatSession._(model, Session.createHandle(model, options.toJson()));

  /// Non-streaming completion. Returns the full text plus tool calls and
  /// usage counters. Prefer [completeStreaming] for anything user-facing —
  /// it removes the perceived latency of the first token.
  Future<ChatCompletion> complete(ChatRequest request) async {
    final bindings = NativeLibrary.instance.bindings;
    final result = await withCString<Future<Map<String, Object?>>>(
      request.toJsonString(),
      (ptr) => runSimpleJob(
        (completionPtr, userData, outJob) =>
            bindings.flm_session_complete_async(
          handle,
          ptr,
          nullptr,
          completionPtr,
          userData,
          outJob,
        ),
      ),
    );
    return ChatCompletion.fromJson(result);
  }

  /// Streaming completion. Deltas arrive as [TextDelta], [ReasoningDelta],
  /// [ToolCallDelta], [UsageDelta] and a terminal [CompletedDelta].
  ///
  /// The stream is single-subscription. Cancelling the subscription calls
  /// `flm_job_cancel`, which unwinds generation on the core side.
  Stream<SessionDelta> completeStreaming(ChatRequest request) {
    final bindings = NativeLibrary.instance.bindings;
    late StreamController<SessionDelta> controller;
    JobHandles<SessionDelta>? handles;
    controller = StreamController<SessionDelta>(
      onListen: () {
        withCString<void>(request.toJsonString(), (ptr) {
          handles = runStreamingJob(
            (deltaPtr, completionPtr, userData, outJob) =>
                bindings.flm_session_complete_async(
              handle,
              ptr,
              deltaPtr,
              completionPtr,
              userData,
              outJob,
            ),
          );
          handles!.stream.listen(
            controller.add,
            onError: controller.addError,
            onDone: controller.close,
          );
          handles!.result.catchError((Object e, StackTrace st) {
            // Errors also flow through the stream, so completing the future's
            // error here would double-notify. Swallow and rely on the stream.
            return <String, Object?>{};
          });
        });
      },
      onCancel: () {
        handles?.cancel();
      },
    );
    return controller.stream;
  }

  /// Submit results for tool calls the model asked for. Continues the turn.
  Stream<SessionDelta> submitToolResults(List<ToolResult> results) {
    final bindings = NativeLibrary.instance.bindings;
    final payload = jsonEncode(results.map((r) => r.toJson()).toList());
    late StreamController<SessionDelta> controller;
    JobHandles<SessionDelta>? handles;
    controller = StreamController<SessionDelta>(
      onListen: () {
        withCString<void>(payload, (ptr) {
          handles = runStreamingJob(
            (deltaPtr, completionPtr, userData, outJob) =>
                bindings.flm_session_submit_tool_results_async(
              handle,
              ptr,
              deltaPtr,
              completionPtr,
              userData,
              outJob,
            ),
          );
          handles!.stream.listen(
            controller.add,
            onError: controller.addError,
            onDone: controller.close,
          );
          handles!.result.catchError((_) => <String, Object?>{});
        });
      },
      onCancel: () => handles?.cancel(),
    );
    return controller.stream;
  }

  /// Number of completed turns in this session's history.
  int get turnCount {
    final out = calloc<Size>();
    try {
      final status =
          NativeLibrary.instance.bindings.flm_session_get_turn_count(handle, out);
      checkStatus(status,
          fallbackMessage: 'flm_session_get_turn_count failed');
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  /// Drop the last [count] turns and rewind the generator state.
  void undoTurns(int count) {
    final status =
        NativeLibrary.instance.bindings.flm_session_undo_turns(handle, count);
    checkStatus(status, fallbackMessage: 'flm_session_undo_turns failed');
  }

  /// Clear all conversation history, keeping the session and its options.
  void clearHistory() {
    final status =
        NativeLibrary.instance.bindings.flm_session_clear_history(handle);
    checkStatus(status, fallbackMessage: 'flm_session_clear_history failed');
  }

  /// Serialize conversation history so it can be restored after the process
  /// is killed. On mobile that is routine, not exceptional.
  Map<String, Object?> exportHistory() {
    final bindings = NativeLibrary.instance.bindings;
    final out = calloc<Pointer<Char>>();
    try {
      final status = bindings.flm_session_export_history_json(handle, out);
      checkStatus(status,
          fallbackMessage: 'flm_session_export_history_json failed');
      try {
        return jsonDecode(takeOutString(out.value)) as Map<String, Object?>;
      } finally {
        bindings.flm_string_free(out.value);
      }
    } finally {
      calloc.free(out);
    }
  }

  /// Restore history previously produced by [exportHistory].
  void restoreHistory(Map<String, Object?> history) {
    withCString(jsonEncode(history), (ptr) {
      final status = NativeLibrary.instance.bindings
          .flm_session_restore_history_json(handle, ptr);
      checkStatus(status,
          fallbackMessage: 'flm_session_restore_history_json failed');
    });
  }
}
