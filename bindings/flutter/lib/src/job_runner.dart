// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings/bindings.dart' as raw;
import 'bindings/dart_bridge.dart';
import 'bindings/native_library.dart';
import 'cancel_token.dart';
import 'error_capture.dart';
import 'models/delta.dart';
import 'models/errors.dart';
import 'models/progress.dart';
import 'native_strings.dart';

/// The signature every `flm_*_async` entry point on the ABI shares: given the
/// progress / delta / completion function pointers and a `user_data`, kick off
/// the work and write the job handle to `out_job`.
///
/// The wrappers in [JobRunner] hide the specific ABI call; this typedef is
/// what they invoke to actually start work.
typedef StartJob = int Function({
  required Pointer<
          NativeFunction<
              Int32 Function(Uint64, Pointer<raw.flm_progress>,
                  Pointer<Void>)>>
      onProgress,
  required Pointer<
          NativeFunction<
              Int32 Function(Uint64, Pointer<raw.flm_delta>, Pointer<Void>)>>
      onDelta,
  required Pointer<NativeFunction<raw.flm_completion_callback_native>> onComplete,
  required Pointer<Void> userData,
  required Pointer<Uint64> outJob,
});

/// Runs a single `flm_*_async` invocation and its callbacks.
///
/// Ownership model:
/// * The runner allocates one [FlmDartBridgeCtx] on the native heap.
/// * Three `NativeCallable.listener`s (progress, delta, completion) are
///   created and their `nativeFunction` pointers stored in the ctx.
/// * The ctx pointer is handed to the C ABI as `user_data`.
/// * When the ABI reports completion, the completer resolves, listeners are
///   closed, and the ctx and its pointer are freed.
///
/// Threading:
/// The core dispatches every callback on one of its job-pool threads. It is
/// **not** safe to run arbitrary Dart on that thread — the VM is not
/// re-entrant from foreign threads. `NativeCallable.listener` is the right
/// primitive here: it wraps the Dart callback in a stub that posts a message
/// onto this isolate's receive port and returns. The actual Dart code then
/// executes when the event loop picks up the message. A plain
/// `Pointer.fromFunction` (or `NativeCallable.isolateLocal`) would crash the
/// VM the first time the core reached back into Dart from a job thread — this
/// is the single easiest mistake to make when adding new async entry points.
class JobRunner {
  JobRunner._({
    required this.streamProgress,
    required this.streamDeltas,
  });

  /// Whether the caller wants progress events surfaced through [progressStream].
  final bool streamProgress;

  /// Whether the caller wants deltas surfaced through [deltaStream].
  final bool streamDeltas;

  final Completer<Map<String, Object?>> _resultCompleter =
      Completer<Map<String, Object?>>();

  StreamController<Progress>? _progressController;
  StreamController<SessionDelta>? _deltaController;

  NativeCallable<
      Void Function(Uint64, Pointer<raw.flm_progress>, Pointer<Void>)>? _progressListener;

  NativeCallable<
      Void Function(Uint64, Pointer<raw.flm_delta>, Pointer<Void>)>? _deltaListener;

  NativeCallable<raw.flm_completion_callback_native>? _completionListener;

  Pointer<FlmDartBridgeCtx>? _ctxPtr;

  int _jobHandle = raw.FLM_INVALID_HANDLE;
  bool _finalized = false;

  /// Job handle assigned by the ABI. Only meaningful once [start] returns.
  int get jobHandle => _jobHandle;

  /// Future that resolves to the parsed job result JSON, or throws a
  /// [FoundryLocalException] on failure.
  Future<Map<String, Object?>> get result => _resultCompleter.future;

  /// Progress events, if [streamProgress] is true. Never null if streamed.
  Stream<Progress> get progressStream {
    assert(streamProgress, 'progress streaming was not requested');
    return _progressController!.stream;
  }

  /// Streaming deltas, if [streamDeltas] is true.
  Stream<SessionDelta> get deltaStream {
    assert(streamDeltas, 'delta streaming was not requested');
    return _deltaController!.stream;
  }

  /// Set up the ctx + listeners and hand them to [start]. Throws immediately
  /// if the ABI refuses to accept the request.
  void start(StartJob start) {
    final ctx = calloc<FlmDartBridgeCtx>();
    _ctxPtr = ctx;
    ctx.ref.version = 1;
    ctx.ref.user_data = nullptr;

    // Only wire the listeners the caller asked for. The C shim skips a NULL
    // forwarder pointer, so unused kinds do not fire at all.
    Pointer<
            NativeFunction<
                Int32 Function(Uint64, Pointer<raw.flm_progress>,
                    Pointer<Void>)>>
        progressPtr = nullptr;
    Pointer<
            NativeFunction<
                Int32 Function(Uint64, Pointer<raw.flm_delta>,
                    Pointer<Void>)>>
        deltaPtr = nullptr;

    if (streamProgress) {
      _progressController = StreamController<Progress>(
        onCancel: _cancelJob,
      );
      final listener = NativeCallable<
          Void Function(Uint64, Pointer<raw.flm_progress>,
              Pointer<Void>)>.listener(_onProgress);
      _progressListener = listener;
      ctx.ref.on_progress = listener.nativeFunction;
      progressPtr = DartBridge.progressAdapter();
    } else {
      ctx.ref.on_progress = nullptr;
    }

    if (streamDeltas) {
      _deltaController = StreamController<SessionDelta>(
        onCancel: _cancelJob,
      );
      final listener = NativeCallable<
          Void Function(Uint64, Pointer<raw.flm_delta>,
              Pointer<Void>)>.listener(_onDelta);
      _deltaListener = listener;
      ctx.ref.on_delta = listener.nativeFunction;
      deltaPtr = DartBridge.deltaAdapter();
    } else {
      ctx.ref.on_delta = nullptr;
    }

    final completionListener = NativeCallable<raw.flm_completion_callback_native>
        .listener(_onCompletion);
    _completionListener = completionListener;
    ctx.ref.on_complete = completionListener.nativeFunction;

    final outJob = calloc<Uint64>();
    try {
      final status = start(
        onProgress: progressPtr,
        onDelta: deltaPtr,
        // Route completion through the C trampoline too. `error_json` is
        // stack-local in the core (job.cc:156) — passing the listener
        // directly would let the pointer dangle for exactly the same
        // reason the delta pointer does. The trampoline strdup's it and
        // Dart frees it in `_onCompletion`'s finally.
        onComplete: DartBridge.completeAdapter(),
        userData: ctx.cast<Void>(),
        outJob: outJob,
      );
      if (status != raw.FlmStatus.ok) {
        // ABI refused to enqueue the job. No callbacks will fire, so tear
        // down everything we set up above and surface the last-error.
        _teardownWithoutJob();
        throwLastError(status);
      }
      _jobHandle = outJob.value;
    } finally {
      calloc.free(outJob);
    }
  }

  void _cancelJob() {
    if (_jobHandle != raw.FLM_INVALID_HANDLE) {
      NativeLibrary.instance.bindings.flm_job_cancel(_jobHandle);
    }
  }

  // The native core's C shim has already deep-copied `ptr` and
  // the strings it points at onto the heap before this listener runs — see
  // the top-of-file comment on why (the raw core pointer would be freed by
  // the time this asynchronous listener body executes). We only need to
  // read the fields, dispatch, and free.
  void _onProgress(int job, Pointer<raw.flm_progress> ptr, Pointer<Void> _) {
    if (ptr == nullptr) return;
    try {
      if (_progressController?.isClosed ?? true) return;
      final progress = Progress.fromNative(
        ptr.ref,
        cStringToDart(ptr.ref.stage),
        detail:
            ptr.ref.detail == nullptr ? null : cStringToDart(ptr.ref.detail),
      );
      _progressController!.add(progress);
    } finally {
      DartBridge.freeProgress(ptr);
    }
  }

  void _onDelta(int job, Pointer<raw.flm_delta> ptr, Pointer<Void> _) {
    if (ptr == nullptr) return;
    try {
      if (_deltaController?.isClosed ?? true) return;
      _deltaController!.add(SessionDelta.fromNative(ptr));
    } finally {
      DartBridge.freeDelta(ptr);
    }
  }

  void _onCompletion(
      int job, int status, Pointer<Char> errorJson, Pointer<Void> _) {
    // `errorJson` is now heap-owned by the C shim; must be freed here.
    try {
      final String? err =
          errorJson == nullptr ? null : cStringToDart(errorJson);

      // Regardless of success or failure, close the delta / progress streams
      // so consumers see `done` and any StreamSubscription.cancel completes.
      void closeStreams() {
        _progressController?.close();
        _deltaController?.close();
      }

      if (status == raw.FlmStatus.ok) {
        final resultJson = _takeResultJson();
        Map<String, Object?> parsed = const <String, Object?>{};
        if (resultJson != null && resultJson.isNotEmpty) {
          try {
            final decoded = jsonDecode(resultJson);
            if (decoded is Map<String, Object?>) {
              parsed = decoded;
            } else if (decoded is Map) {
              parsed = decoded.cast<String, Object?>();
            }
          } on FormatException {
            parsed = <String, Object?>{'raw': resultJson};
          }
        }
        _resultCompleter.complete(parsed);
      } else {
        final ex = exceptionFromErrorJson(status, err);
        _progressController?.addError(ex);
        _deltaController?.addError(ex);
        _resultCompleter.completeError(ex);
      }
      closeStreams();
      _finalize();
    } finally {
      if (errorJson != nullptr) {
        DartBridge.freeString(errorJson);
      }
    }
  }

  String? _takeResultJson() {
    final bindings = NativeLibrary.instance.bindings;
    final out = calloc<Pointer<Char>>();
    try {
      final status = bindings.flm_job_take_result_json(_jobHandle, out);
      if (status != raw.FlmStatus.ok) {
        return null;
      }
      final ptr = out.value;
      if (ptr == nullptr) return null;
      try {
        return takeOutString(ptr);
      } finally {
        bindings.flm_string_free(ptr);
      }
    } finally {
      calloc.free(out);
    }
  }

  void _finalize() {
    if (_finalized) return;
    _finalized = true;
    final bindings = NativeLibrary.instance.bindings;
    if (_jobHandle != raw.FLM_INVALID_HANDLE) {
      bindings.flm_job_release(_jobHandle);
      _jobHandle = raw.FLM_INVALID_HANDLE;
    }
    _completionListener?.close();
    _progressListener?.close();
    _deltaListener?.close();
    _completionListener = null;
    _progressListener = null;
    _deltaListener = null;
    if (_ctxPtr != null) {
      calloc.free(_ctxPtr!);
      _ctxPtr = null;
    }
  }

  void _teardownWithoutJob() {
    _completionListener?.close();
    _progressListener?.close();
    _deltaListener?.close();
    _completionListener = null;
    _progressListener = null;
    _deltaListener = null;
    if (_ctxPtr != null) {
      calloc.free(_ctxPtr!);
      _ctxPtr = null;
    }
    _progressController?.close();
    _deltaController?.close();
    _finalized = true;
  }
}

/// Run an async ABI call that reports only progress + completion. Returns the
/// completion Future; progress events (if requested) are emitted on [onProgress].
///
/// The Future may complete with a [FoundryLocalException].
///
/// Pass [cancelToken] to make the call cancellable from outside — once the
/// token fires the runner calls `flm_job_cancel` on the freshly-started job
/// and the Future then resolves with a [CancelledException]. The wiring is
/// safe to arm before or after the job has started: if the token was already
/// cancelled by the time the caller reaches `await`, cancel fires as soon as
/// the job handle is known.
Future<Map<String, Object?>> runProgressJob({
  required int Function(
    Pointer<NativeFunction<Int32 Function(Uint64, Pointer<raw.flm_progress>, Pointer<Void>)>> onProgress,
    Pointer<NativeFunction<raw.flm_completion_callback_native>> onComplete,
    Pointer<Void> userData,
    Pointer<Uint64> outJob,
  ) abiCall,
  Sink<Progress>? onProgress,
  CancelToken? cancelToken,
}) async {
  final runner = JobRunner._(
    streamProgress: onProgress != null,
    streamDeltas: false,
  );
  StreamSubscription<Progress>? sub;
  StreamSubscription<void>? cancelSub;
  if (onProgress != null) {
    sub = runner.progressStream.listen(onProgress.add, onError: (_) {});
  }
  try {
    runner.start(({
      required onProgress,
      required onDelta,
      required onComplete,
      required userData,
      required outJob,
    }) =>
        abiCall(onProgress, onComplete, userData, outJob));
    if (cancelToken != null) {
      cancelSub =
          cancelToken.whenCancelled.asStream().listen((_) => runner._cancelJob());
    }
    return await runner.result;
  } finally {
    await sub?.cancel();
    await cancelSub?.cancel();
  }
}

/// Run an async ABI call that reports progress + completion and expose the
/// result as a [JobHandles] with a cancel hook wired to `flm_job_cancel`.
///
/// The main use for this primitive today is streaming progress from any ABI
/// call that surfaces intermediate work; [Model.load] itself uses the
/// [runProgressJob] wrapper because it just wants a Future plus optional
/// callback.
JobHandles<Progress> runProgressStreamJob(
  int Function(
    Pointer<NativeFunction<Int32 Function(Uint64, Pointer<raw.flm_progress>, Pointer<Void>)>> onProgress,
    Pointer<NativeFunction<raw.flm_completion_callback_native>> onComplete,
    Pointer<Void> userData,
    Pointer<Uint64> outJob,
  ) abiCall,
) {
  final runner = JobRunner._(streamProgress: true, streamDeltas: false);
  runner.start(({
    required onProgress,
    required onDelta,
    required onComplete,
    required userData,
    required outJob,
  }) =>
      abiCall(onProgress, onComplete, userData, outJob));
  return JobHandles<Progress>(
    stream: runner.progressStream,
    result: runner.result,
    cancel: runner._cancelJob,
    jobHandle: () => runner.jobHandle,
  );
}

/// Run an async ABI call with only a completion callback (no progress, no
/// deltas). Pass [cancelToken] to make the call cancellable — see
/// [runProgressJob] for the semantics.
Future<Map<String, Object?>> runSimpleJob(
  int Function(
    Pointer<NativeFunction<raw.flm_completion_callback_native>> onComplete,
    Pointer<Void> userData,
    Pointer<Uint64> outJob,
  ) abiCall, {
  CancelToken? cancelToken,
}) async {
  final runner = JobRunner._(streamProgress: false, streamDeltas: false);
  StreamSubscription<void>? cancelSub;
  runner.start(({
    required onProgress,
    required onDelta,
    required onComplete,
    required userData,
    required outJob,
  }) =>
      abiCall(onComplete, userData, outJob));
  if (cancelToken != null) {
    cancelSub =
        cancelToken.whenCancelled.asStream().listen((_) => runner._cancelJob());
  }
  try {
    return await runner.result;
  } finally {
    await cancelSub?.cancel();
  }
}

/// Run an async ABI call that streams deltas.
///
/// Returns both the delta stream and the completion future. The stream closes
/// on completion (success or failure); the future carries the final JSON
/// result (`text`, `finish_reason`, `usage`, `tool_calls`, …).
JobHandles<SessionDelta> runStreamingJob(
  int Function(
    Pointer<NativeFunction<Int32 Function(Uint64, Pointer<raw.flm_delta>, Pointer<Void>)>> onDelta,
    Pointer<NativeFunction<raw.flm_completion_callback_native>> onComplete,
    Pointer<Void> userData,
    Pointer<Uint64> outJob,
  ) abiCall,
) {
  final runner = JobRunner._(streamProgress: false, streamDeltas: true);
  runner.start(({
    required onProgress,
    required onDelta,
    required onComplete,
    required userData,
    required outJob,
  }) =>
      abiCall(onDelta, onComplete, userData, outJob));
  return JobHandles<SessionDelta>(
    stream: runner.deltaStream,
    result: runner.result,
    cancel: runner._cancelJob,
    jobHandle: () => runner.jobHandle,
  );
}

/// Handles for a streaming job.
class JobHandles<T> {
  const JobHandles({
    required this.stream,
    required this.result,
    required this.cancel,
    required this.jobHandle,
  });

  final Stream<T> stream;
  final Future<Map<String, Object?>> result;
  final void Function() cancel;
  final int Function() jobHandle;
}
