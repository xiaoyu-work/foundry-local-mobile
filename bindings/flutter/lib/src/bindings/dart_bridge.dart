// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:ffi';

import 'bindings.dart' as raw;
import 'native_library.dart';

/// Adapter layer over the tiny C shim in `src/flm_dart_bridge.c`.
///
/// The shim exists for two reasons:
///
/// 1. Three ABI callback typedefs return int32_t
///    (`flm_progress_callback`, `flm_delta_callback`, `flm_transport_send`),
///    but `NativeCallable.listener` only supports void-returning callbacks.
///    The trampolines wrap each with an int32_t-returning C function that
///    always returns 0; cancellation is expressed through `flm_job_cancel`
///    and transport failures through `flm_transport_report_complete`.
///
/// 2. `NativeCallable.listener` is asynchronous: it queues an invocation
///    onto the isolate's port and returns. By the time Dart reads the
///    pointer, the core has destroyed the borrowed struct on its thread's
///    stack (see flm_types.h — every `const char*` and struct handed to a
///    callback is valid for the duration of that call only). The shim
///    therefore deep-copies the payload synchronously and hands the owned
///    heap pointer to Dart; Dart releases it via the matching
///    `flm_dart_bridge_free_*` helper below.
///
///    The one path that does NOT copy is transport `send`: the core blocks
///    the calling thread until `flm_transport_report_complete` fires, so
///    the borrowed `flm_http_request` stays alive across the hand-off. See
///    the "one exception" note in flm_types.h.
///
/// Every entry point in this file returns a raw pointer to a symbol resolved
/// through the shared [NativeLibrary]. The pointers are cached because a
/// process-wide library lookup is a syscall on Android.
final class DartBridge {
  DartBridge._();

  static Pointer<
      NativeFunction<
          Int32 Function(Uint64, Pointer<raw.flm_progress>,
              Pointer<Void>)>>? _progressAdapter;

  static Pointer<
      NativeFunction<
          Int32 Function(Uint64, Pointer<raw.flm_delta>, Pointer<Void>)>>? _deltaAdapter;

  static Pointer<NativeFunction<raw.flm_completion_callback_native>>? _completeAdapter;

  static Pointer<
      NativeFunction<
          Int32 Function(
              Pointer<raw.flm_http_request>, Pointer<Void>)>>? _sendAdapter;

  static void Function(Pointer<raw.flm_progress>)? _freeProgress;
  static void Function(Pointer<raw.flm_delta>)? _freeDelta;
  static void Function(Pointer<Char>)? _freeString;

  /// Function pointer for `flm_dart_bridge_progress`. Pass this — not a
  /// `NativeCallable.listener`'s `nativeFunction` — to
  /// `flm_*_async(..., on_progress=…, user_data=ctx, ...)`.
  static Pointer<
      NativeFunction<
          Int32 Function(Uint64, Pointer<raw.flm_progress>,
              Pointer<Void>)>> progressAdapter() {
    return _progressAdapter ??= NativeLibrary
        .process
        .lookup<
            NativeFunction<
                Int32 Function(Uint64, Pointer<raw.flm_progress>,
                    Pointer<Void>)>>('flm_dart_bridge_progress');
  }

  static Pointer<
      NativeFunction<
          Int32 Function(
              Uint64, Pointer<raw.flm_delta>, Pointer<Void>)>> deltaAdapter() {
    return _deltaAdapter ??= NativeLibrary.process.lookup<
        NativeFunction<
            Int32 Function(Uint64, Pointer<raw.flm_delta>,
                Pointer<Void>)>>('flm_dart_bridge_delta');
  }

  /// Function pointer for `flm_dart_bridge_complete`. The completion
  /// callback is void-returning so this exists only to deep-copy `error_json`
  /// (which the core would otherwise free before Dart read it).
  static Pointer<NativeFunction<raw.flm_completion_callback_native>>
      completeAdapter() {
    return _completeAdapter ??= NativeLibrary.process
        .lookup<NativeFunction<raw.flm_completion_callback_native>>(
      'flm_dart_bridge_complete',
    );
  }

  static Pointer<
      NativeFunction<
          Int32 Function(
              Pointer<raw.flm_http_request>, Pointer<Void>)>> sendAdapter() {
    return _sendAdapter ??= NativeLibrary.process.lookup<
        NativeFunction<
            Int32 Function(Pointer<raw.flm_http_request>,
                Pointer<Void>)>>('flm_dart_bridge_send');
  }

  /// Release an owned progress copy handed to a listener. MUST be called
  /// inside a try/finally so a parse error cannot leak the heap allocation.
  static void freeProgress(Pointer<raw.flm_progress> owned) {
    (_freeProgress ??= NativeLibrary.process.lookupFunction<
        Void Function(Pointer<raw.flm_progress>),
        void Function(Pointer<raw.flm_progress>)>(
      'flm_dart_bridge_free_progress',
    ))(owned);
  }

  static void freeDelta(Pointer<raw.flm_delta> owned) {
    (_freeDelta ??= NativeLibrary.process.lookupFunction<
        Void Function(Pointer<raw.flm_delta>),
        void Function(Pointer<raw.flm_delta>)>(
      'flm_dart_bridge_free_delta',
    ))(owned);
  }

  static void freeString(Pointer<Char> owned) {
    (_freeString ??= NativeLibrary.process.lookupFunction<
        Void Function(Pointer<Char>),
        void Function(Pointer<Char>)>(
      'flm_dart_bridge_free_string',
    ))(owned);
  }
}

/// Layout of the C `flm_dart_bridge_ctx` struct. Owned by Dart; freed by
/// [JobRunner] after the job completes and its listeners are closed.
final class FlmDartBridgeCtx extends Struct {
  @Uint32()
  external int version;

  external Pointer<NativeFunction<Void Function(Uint64, Pointer<raw.flm_progress>, Pointer<Void>)>>
      on_progress;

  external Pointer<NativeFunction<Void Function(Uint64, Pointer<raw.flm_delta>, Pointer<Void>)>>
      on_delta;

  external Pointer<NativeFunction<raw.flm_completion_callback_native>> on_complete;

  external Pointer<NativeFunction<Void Function(Pointer<raw.flm_http_request>, Pointer<Void>)>>
      on_send;

  external Pointer<Void> user_data;
}
