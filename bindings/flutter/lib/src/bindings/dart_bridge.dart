// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:ffi';

import 'bindings.dart' as raw;
import 'native_library.dart';

/// Adapter layer over the tiny C shim in `src/flm_dart_bridge.c`.
///
/// The shim exists to make three int32_t-returning ABI callbacks
/// (`flm_progress_callback`, `flm_delta_callback`, `flm_transport_send`)
/// callable from Dart, since `NativeCallable.listener` only supports
/// void-returning callbacks. Each trampoline invokes a void listener supplied
/// through the [FlmDartBridgeCtx] and returns 0 unconditionally — cancellation
/// is expressed through `flm_job_cancel` and transport failures are surfaced
/// through `flm_transport_report_complete`.
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

  static Pointer<
      NativeFunction<
          Int32 Function(
              Pointer<raw.flm_http_request>, Pointer<Void>)>>? _sendAdapter;

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

  static Pointer<
      NativeFunction<
          Int32 Function(
              Pointer<raw.flm_http_request>, Pointer<Void>)>> sendAdapter() {
    return _sendAdapter ??= NativeLibrary.process.lookup<
        NativeFunction<
            Int32 Function(Pointer<raw.flm_http_request>,
                Pointer<Void>)>>('flm_dart_bridge_send');
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

  external Pointer<NativeFunction<Void Function(Pointer<raw.flm_http_request>, Pointer<Void>)>>
      on_send;

  external Pointer<Void> user_data;
}
