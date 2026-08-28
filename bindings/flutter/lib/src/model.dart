// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import 'audio_session.dart';
import 'bindings/native_library.dart';
import 'cancel_token.dart';
import 'chat_session.dart';
import 'embedding_session.dart';
import 'error_capture.dart';
import 'job_runner.dart';
import 'models/model_info.dart';
import 'models/progress.dart';
import 'native_strings.dart';

/// Options passed to [Model.load].
class LoadOptions {
  const LoadOptions({this.executionProvider, this.providerOptions});

  final String? executionProvider;

  /// Key-value EP configuration forwarded as `provider_options` to the OGA
  /// session. Keys and values are provider-specific.
  final Map<String, String>? providerOptions;

  Map<String, Object?> toJson() => <String, Object?>{
        if (executionProvider != null) 'execution_provider': executionProvider,
        if (providerOptions != null && providerOptions!.isNotEmpty)
          'provider_options': providerOptions,
      };
}

/// Result of a successful [Model.load] call. Mirrors the
/// `flm_job_take_result_json` shape for `flm_model_load_async`:
/// `{ "path": "...", "bytes": 542113792 }`.
@immutable
class LoadResult {
  const LoadResult({required this.path, required this.bytes});

  /// Absolute on-disk path the model was loaded from. Same value as
  /// [Model.path] once loading has finished.
  final String path;

  /// Number of bytes now resident in memory for this model.
  final int bytes;

  factory LoadResult.fromJson(Map<String, Object?> json) => LoadResult(
        path: json['path'] as String? ?? '',
        bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      );
}

/// A model handle owned by the app.
class Model {
  Model._(this._handle);

  factory Model.fromHandle(int handle) {
    return Model._(handle);
  }

  final int _handle;
  bool _released = false;

  /// Underlying `flm_model` handle. Exposed for interop between sibling
  /// classes; do not store this externally.
  int get handle => _handle;

  /// Metadata for the model.
  ModelInfo get info {
    _ensureAlive();
    final bindings = NativeLibrary.instance.bindings;
    final out = calloc<Pointer<Char>>();
    try {
      final status = bindings.flm_model_get_info_json(_handle, out);
      checkStatus(status, fallbackMessage: 'flm_model_get_info_json failed');
      try {
        final s = takeOutString(out.value);
        return ModelInfo.fromJson(jsonDecode(s) as Map<String, Object?>);
      } finally {
        bindings.flm_string_free(out.value);
      }
    } finally {
      calloc.free(out);
    }
  }

  /// Metadata for the model.
  ModelInfo getInfo() => info;

  /// Whether the underlying files are fully present on disk.
  bool get isCached {
    _ensureAlive();
    final out = calloc<Int32>();
    try {
      final status =
          NativeLibrary.instance.bindings.flm_model_is_cached(_handle, out);
      checkStatus(status, fallbackMessage: 'flm_model_is_cached failed');
      return out.value != 0;
    } finally {
      calloc.free(out);
    }
  }

  /// Whether the model is loaded into memory.
  bool get isLoaded {
    _ensureAlive();
    final out = calloc<Int32>();
    try {
      final status =
          NativeLibrary.instance.bindings.flm_model_is_loaded(_handle, out);
      checkStatus(status, fallbackMessage: 'flm_model_is_loaded failed');
      return out.value != 0;
    } finally {
      calloc.free(out);
    }
  }

  /// Absolute on-disk path.
  String get path {
    _ensureAlive();
    final bindings = NativeLibrary.instance.bindings;
    final out = calloc<Pointer<Char>>();
    try {
      final status = bindings.flm_model_get_path(_handle, out);
      checkStatus(status, fallbackMessage: 'flm_model_get_path failed');
      try {
        return takeOutString(out.value);
      } finally {
        bindings.flm_string_free(out.value);
      }
    } finally {
      calloc.free(out);
    }
  }

  /// Load the model into memory.
  ///
  /// This is primarily useful after [unload]. Models returned by
  /// [FoundryLocal.loadModel] are already loaded.
  Future<LoadResult> load({
    LoadOptions options = const LoadOptions(),
    void Function(Progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    _ensureAlive();
    final bindings = NativeLibrary.instance.bindings;

    Sink<Progress>? sink;
    StreamController<Progress>? controller;
    if (onProgress != null) {
      controller = StreamController<Progress>();
      sink = controller.sink;
      controller.stream.listen(onProgress);
    }

    try {
      final result = await withCString<Future<Map<String, Object?>>>(
        jsonEncode(options.toJson()),
        (optsPtr) => runProgressJob(
          abiCall: (progressPtr, completionPtr, userDataPtr, outJob) =>
              bindings.flm_model_load_async(
            _handle,
            optsPtr,
            progressPtr,
            completionPtr,
            userDataPtr,
            outJob,
          ),
          onProgress: sink,
          cancelToken: cancelToken,
        ),
      );
      return LoadResult.fromJson(result);
    } finally {
      await controller?.close();
    }
  }

  /// Unload the model, releasing its memory. Active sessions are stopped.
  Future<void> unload() async {
    _ensureAlive();
    await runSimpleJob(
      (completionPtr, userData, outJob) =>
          NativeLibrary.instance.bindings.flm_model_unload_async(
        _handle,
        completionPtr,
        userData,
        outJob,
      ),
    );
  }

  /// Create a chat session over this (loaded) model.
  ChatSession createChatSession({ChatSessionOptions? options}) {
    _ensureAlive();
    return ChatSession.create(this, options ?? const ChatSessionOptions());
  }

  /// Create a speech-to-text session over this (loaded) model.
  AudioSession createAudioSession({AudioSessionOptions? options}) {
    _ensureAlive();
    return AudioSession.create(this, options ?? const AudioSessionOptions());
  }

  /// Create an embedding session over this (loaded) model.
  EmbeddingSession createEmbeddingSession() {
    _ensureAlive();
    return EmbeddingSession.create(this);
  }

  /// Release the model handle. The underlying model files on disk are not
  /// touched.
  void release() {
    if (_released) return;
    _released = true;
    NativeLibrary.instance.bindings.flm_model_release(_handle);
  }

  /// Release the model handle. Alias for [release].
  void dispose() => release();

  void _ensureAlive() {
    if (_released) throw StateError('Model handle has been released.');
  }
}
