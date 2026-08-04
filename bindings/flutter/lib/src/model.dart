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
import 'model_package.dart';
import 'models/model_info.dart';
import 'models/progress.dart';
import 'native_strings.dart';

/// Options passed to [Model.load].
class LoadOptions {
  const LoadOptions({this.executionProvider, this.device});
  final String? executionProvider;
  final String? device;
  Map<String, Object?> toJson() => <String, Object?>{
        if (executionProvider != null) 'execution_provider': executionProvider,
        if (device != null) 'device': device,
      };
}

/// Result of a successful [Model.load] call. Mirrors the
/// `flm_job_take_result_json` shape for `flm_model_load_async`:
/// `{ "path": "...", "bytes": 542113792 }`.
@immutable
class LoadResult {
  const LoadResult({required this.path, required this.bytes});

  /// Absolute on-disk path the model was loaded from. Same value as
  /// [Model.path] once loading has finished, and mirrors `flm_model_get_path`.
  final String path;

  /// Number of bytes now resident in memory for this model. Useful for
  /// telemetry and for driving `flm_manager_notify_lifecycle` cache decisions
  /// once several models are loaded.
  final int bytes;

  factory LoadResult.fromJson(Map<String, Object?> json) => LoadResult(
        path: json['path'] as String? ?? '',
        bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      );
}

/// A model handle owned by the app. Comes from
/// [FoundryLocal.addModelSource] (the only supported acquisition path on
/// mobile) or from [Catalog.getModel]/[Catalog.getModelById] for a model that
/// has already been added.
class Model {
  Model._(this._handle);

  /// Internal factory. Callers should reach models through [Catalog] or
  /// [FoundryLocal.addModelSource] rather than constructing them directly.
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

  /// Absolute on-disk path, or an empty string when not cached.
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

  /// Whether this handle refers to a model package (as opposed to a flat
  /// model). Use [asPackage] to get a [ModelPackage] view when it does.
  bool get isPackage {
    _ensureAlive();
    final out = calloc<Int32>();
    try {
      final status =
          NativeLibrary.instance.bindings.flm_model_is_package(_handle, out);
      checkStatus(status, fallbackMessage: 'flm_model_is_package failed');
      return out.value != 0;
    } finally {
      calloc.free(out);
    }
  }

  /// Nullable convenience getter: this handle's [ModelPackage] view when it
  /// refers to a package, `null` otherwise. Prefer this over [asPackage] when
  /// the caller wants to branch on package-ness rather than treat "flat
  /// model" as an exception.
  ModelPackage? get package => isPackage ? ModelPackage.internal(this) : null;

  /// [ModelPackage] view of this handle. Throws [StateError] if the model is
  /// not a package. See [package] for a nullable variant.
  ModelPackage asPackage() {
    if (!isPackage) {
      throw StateError('Model ${info.alias} is not a package.');
    }
    return ModelPackage.internal(this);
  }

  /// Load the model into memory.
  ///
  /// Does **not** download on demand: the model must already be present on
  /// disk (via a bundled or remote [ModelSource] registered through
  /// [FoundryLocal.addModelSource]). If it is not, this rejects with a
  /// `FoundryLocalException` carrying `FLM_ERROR_NOT_IMPLEMENTED`. See the
  /// package README for the model-source flow.
  ///
  /// Progress events (weight-mmap, execution-provider warmup, …) are
  /// delivered to [onProgress] as they arrive. The Future resolves with the
  /// [LoadResult] the core reports when loading is complete.
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

  /// Delete the model's files from the cache.
  Future<void> delete() async {
    _ensureAlive();
    await runSimpleJob(
      (completionPtr, userData, outJob) =>
          NativeLibrary.instance.bindings.flm_model_delete_async(
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

  /// Release the model handle. The underlying files stay in the cache; call
  /// [delete] first to remove them.
  void release() {
    if (_released) return;
    _released = true;
    NativeLibrary.instance.bindings.flm_model_release(_handle);
  }

  void _ensureAlive() {
    if (_released) throw StateError('Model handle has been released.');
  }
}
