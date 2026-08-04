// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings/native_library.dart';
import 'error_capture.dart';
import 'model.dart';
import 'native_strings.dart';

/// Base class for [ChatSession], [AudioSession] and [EmbeddingSession].
///
/// Every session owns a `flm_session` handle; [release] frees it and, per the
/// ABI docs, cancels any in-flight generation.
abstract class Session {
  Session({required Model model, required int handle})
      : _model = model,
        _handle = handle;

  final Model _model;
  final int _handle;
  bool _released = false;

  /// Underlying session handle. Exposed for interop; do not store externally.
  int get handle => _handle;

  Model get model => _model;

  /// Update runtime options (temperature, max_output_tokens, seed…). Same
  /// schema as the constructor.
  void setOptions(Map<String, Object?> options) {
    _ensureAlive();
    withCString(jsonEncode(options), (ptr) {
      final status =
          NativeLibrary.instance.bindings.flm_session_set_options(_handle, ptr);
      checkStatus(status, fallbackMessage: 'flm_session_set_options failed');
    });
  }

  /// Release the session handle and free its KV cache. Idempotent.
  void release() {
    if (_released) return;
    _released = true;
    NativeLibrary.instance.bindings.flm_session_release(_handle);
  }

  void _ensureAlive() {
    if (_released) throw StateError('Session handle has been released.');
  }

  /// Convenience for subclasses: create a session with a specific `type`.
  static int createHandle(Model model, Map<String, Object?> options) {
    final bindings = NativeLibrary.instance.bindings;
    final out = calloc<Uint64>();
    try {
      return withCString(jsonEncode(options), (ptr) {
        final status =
            bindings.flm_session_create(model.handle, ptr, out);
        checkStatus(status, fallbackMessage: 'flm_session_create failed');
        return out.value;
      });
    } finally {
      calloc.free(out);
    }
  }
}
