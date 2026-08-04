// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'audio_session.dart';
import 'bindings/bindings.dart' as raw;
import 'bindings/native_library.dart';
import 'chat_session.dart';
import 'embedding_session.dart';
import 'error_capture.dart';
import 'job_runner.dart';
import 'model_package.dart';
import 'models/model_info.dart';
import 'models/model_variant.dart';
import 'models/progress.dart';
import 'native_strings.dart';

/// Options passed to [Model.download].
class DownloadOptions {
  const DownloadOptions({
    this.allowMetered,
    this.resume = true,
    this.verifyChecksums = true,
  });

  /// Override the manager-level metered-network policy for this download.
  final bool? allowMetered;

  final bool resume;
  final bool verifyChecksums;

  Map<String, Object?> toJson() => <String, Object?>{
        if (allowMetered != null) 'allow_metered': allowMetered,
        'resume': resume,
        'verify_checksums': verifyChecksums,
      };
}

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

/// A catalog model, a bundled model, a model package or one variant of a
/// package. See [isPackage] to distinguish package handles.
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

  /// [ModelPackage] view of this handle. Throws [StateError] if the model is
  /// not a package.
  ModelPackage asPackage() {
    if (!isPackage) {
      throw StateError('Model ${info.alias} is not a package.');
    }
    return ModelPackage.internal(this);
  }

  /// Download the model, streaming progress events. The [Stream] must be
  /// listened to for the download to actually start.
  ///
  /// For a package handle this downloads the currently selected variant plus
  /// the shared assets it references — not the whole package. Call
  /// [ModelPackage.selectBestVariant] first to choose.
  Stream<Progress> download({DownloadOptions options = const DownloadOptions()}) {
    _ensureAlive();
    return _startProgressStream(
      (progressPtr, completionPtr, userData, outJob) {
        return withCString(jsonEncode(options.toJson()), (optsPtr) {
          return NativeLibrary.instance.bindings.flm_model_download_async(
            _handle,
            optsPtr,
            progressPtr,
            completionPtr,
            userData,
            outJob,
          );
        });
      },
    );
  }

  /// Load the model into memory, streaming progress. Downloads the model
  /// first if it is not cached.
  Stream<Progress> load({LoadOptions options = const LoadOptions()}) {
    _ensureAlive();
    return _startProgressStream(
      (progressPtr, completionPtr, userData, outJob) {
        return withCString(jsonEncode(options.toJson()), (optsPtr) {
          return NativeLibrary.instance.bindings.flm_model_load_async(
            _handle,
            optsPtr,
            progressPtr,
            completionPtr,
            userData,
            outJob,
          );
        });
      },
    );
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

  /// Convenience wrapper matching the README quickstart: awaits a full
  /// download rather than exposing the progress stream.
  Future<void> downloadAndWait({
    DownloadOptions options = const DownloadOptions(),
    void Function(Progress)? onProgress,
  }) async {
    final stream = download(options: options);
    if (onProgress == null) {
      await for (final _ in stream) {}
    } else {
      await for (final p in stream) {
        onProgress(p);
      }
    }
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

  /// Start a progress-streaming ABI call and expose the underlying stream.
  ///
  /// Cancellation of the returned subscription is forwarded to
  /// `flm_job_cancel`. The stream reflects the job's underlying progress
  /// stream 1:1, and errors on the job are re-thrown by the stream so
  /// `await for` unwinds naturally.
  Stream<Progress> _startProgressStream(
    int Function(
      Pointer<NativeFunction<Int32 Function(Uint64, Pointer<raw.flm_progress>, Pointer<Void>)>> onProgress,
      Pointer<NativeFunction<raw.flm_completion_callback_native>> onComplete,
      Pointer<Void> userData,
      Pointer<Uint64> outJob,
    ) abiCall,
  ) {
    late StreamController<Progress> controller;
    JobHandles<Progress>? handles;
    StreamSubscription<Progress>? sub;

    controller = StreamController<Progress>(
      onListen: () {
        try {
          handles = runProgressStreamJob(abiCall);
        } catch (e, st) {
          controller.addError(e, st);
          controller.close();
          return;
        }
        sub = handles!.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: () => controller.close(),
        );
        handles!.result.catchError((Object e, StackTrace st) {
          // Errors are also delivered to the stream; swallow here so the
          // Future does not remain uncaught.
          return <String, Object?>{};
        });
      },
      onCancel: () async {
        handles?.cancel();
        await sub?.cancel();
      },
    );
    return controller.stream;
  }
}
