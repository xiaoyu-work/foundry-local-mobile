// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:path_provider/path_provider.dart' as pp;

import 'bindings/bindings.dart' as raw;
import 'bindings/native_library.dart';
import 'error_capture.dart';
import 'job_runner.dart';
import 'lifecycle.dart';
import 'model.dart';
import 'models/config.dart';
import 'models/device_profile.dart';
import 'models/errors.dart';
import 'models/progress.dart';
import 'native_strings.dart';

/// Root object of the SDK. Owns the manager handle and the app-lifecycle
/// bridge; released by [dispose].
class FoundryLocal {
  FoundryLocal._({
    required this.config,
    required int managerHandle,
    required LifecycleBridge lifecycleBridge,
  })  : _managerHandle = managerHandle,
        _lifecycleBridge = lifecycleBridge;

  /// Configuration this instance was created with. Read-only after creation.
  final FoundryLocalConfig config;

  final int _managerHandle;
  final LifecycleBridge _lifecycleBridge;
  bool _disposed = false;

  /// Runtime version reported by the loaded core, or null when the runtime
  /// shared library is missing.
  static String? get runtimeVersion {
    final ptr = NativeLibrary.instance.bindings.flm_runtime_version_string();
    if (ptr == nullptr) return null;
    final s = cStringToDart(ptr);
    return s.isEmpty ? null : s;
  }

  /// SDK version string (matches the plugin's pubspec version).
  static String get sdkVersion =>
      cStringToDart(NativeLibrary.instance.bindings.flm_version_string());

  /// Whether the ONNX Runtime GenAI runtime is present and loadable.
  static bool get isRuntimeAvailable =>
      NativeLibrary.instance.bindings.flm_is_runtime_available() != 0;

  /// Create a manager.
  ///
  /// The plugin fills in `app_data_dir` from `getApplicationSupportDirectory`
  /// unless the caller sets it explicitly, because the core requires a sandbox
  /// path on mobile.
  static Future<FoundryLocal> create(FoundryLocalConfig config) async {
    final bindings = NativeLibrary.instance.bindings;

    var resolvedConfig = config;
    if (config.appDataDir == null) {
      final dir = await pp.getApplicationSupportDirectory();
      resolvedConfig = FoundryLocalConfig(
        appName: config.appName,
        appDataDir: dir.path,
        logLevel: config.logLevel,
        autoUnloadOnBackground: config.autoUnloadOnBackground,
        jobPoolThreads: config.jobPoolThreads,
        additionalOptions: config.additionalOptions,
      );
    }

    late int managerHandle;
    withCString(resolvedConfig.toJsonString(), (cfgPtr) {
      final out = calloc<Uint64>();
      try {
        final status = bindings.flm_manager_create(cfgPtr, out);
        checkStatus(status, fallbackMessage: 'flm_manager_create failed');
        managerHandle = out.value;
      } finally {
        calloc.free(out);
      }
    });

    final lifecycleBridge = LifecycleBridge.attach(managerHandle);
    return FoundryLocal._(
      config: resolvedConfig,
      managerHandle: managerHandle,
      lifecycleBridge: lifecycleBridge,
    );
  }

  /// Live device profile. Recomputed each time — thermal state and available
  /// memory change quickly on a phone.
  DeviceProfile get deviceProfile {
    _ensureAlive();
    final bindings = NativeLibrary.instance.bindings;
    final out = calloc<Pointer<Char>>();
    try {
      final status =
          bindings.flm_manager_get_device_profile_json(_managerHandle, out);
      checkStatus(status,
          fallbackMessage: 'flm_manager_get_device_profile_json failed');
      try {
        final s = takeOutString(out.value);
        final json = jsonDecode(s) as Map<String, Object?>;
        return DeviceProfile.fromJson(json);
      } finally {
        bindings.flm_string_free(out.value);
      }
    } finally {
      calloc.free(out);
    }
  }

  /// Adjust mutable runtime settings without recreating the manager.
  void updateSettings(RuntimeSettings settings) {
    _ensureAlive();
    final bindings = NativeLibrary.instance.bindings;
    withCString(settings.toJsonString(), (ptr) {
      final status = bindings.flm_manager_update_settings(_managerHandle, ptr);
      checkStatus(status,
          fallbackMessage: 'flm_manager_update_settings failed');
    });
  }

  /// Forward an OS lifecycle event to the core. Bindings wire this to the
  /// platform's own notifications automatically via [LifecycleBridge]; apps
  /// rarely need to call it directly.
  void notifyLifecycle(FlmLifecycleEventKind event) {
    _ensureAlive();
    NativeLibrary.instance.bindings
        .flm_manager_notify_lifecycle(_managerHandle, event.code);
  }

  /// Validate, load and register a model from a local filesystem path.
  ///
  /// The returned [Model] is already loaded and ready for session creation.
  Future<Model> loadModel(
    String path, {
    String? executionProvider,
    Map<String, String>? providerOptions,
    void Function(Progress)? onProgress,
  }) async {
    _ensureAlive();
    final bindings = NativeLibrary.instance.bindings;
    final options = LoadOptions(
      executionProvider: executionProvider,
      providerOptions: providerOptions,
    );
    final optionsMap = options.toJson();
    final optionsJson = optionsMap.isEmpty ? null : jsonEncode(optionsMap);

    Sink<Progress>? sink;
    StreamController<Progress>? controller;
    if (onProgress != null) {
      controller = StreamController<Progress>();
      sink = controller.sink;
      controller.stream.listen(onProgress);
    }

    try {
      final result = await withCString<Future<Map<String, Object?>>>(
        path,
        (pathPtr) => withNullableCString<Future<Map<String, Object?>>>(
          optionsJson,
          (optionsPtr) => runProgressJob(
            abiCall: (progressPtr, completionPtr, userDataPtr, outJob) =>
                bindings.flm_manager_load_model_async(
              _managerHandle,
              pathPtr,
              optionsPtr,
              progressPtr,
              completionPtr,
              userDataPtr,
              outJob,
            ),
            onProgress: sink,
          ),
        ),
      );

      final handle =
          (result['model_handle'] as num?)?.toInt() ?? raw.FLM_INVALID_HANDLE;
      if (handle == raw.FLM_INVALID_HANDLE) {
        throw buildException(
          raw.FlmStatus.invalidHandle,
          message:
              'No model handle returned for path "$path" from flm_manager_load_model_async.',
          detail: result,
        );
      }
      return Model.fromHandle(handle);
    } finally {
      await controller?.close();
    }
  }

  /// Shut down the manager, cancel in-flight jobs and unload every model.
  ///
  /// After this returns you may still receive queued completion callbacks
  /// (with `FLM_ERROR_CANCELLED`) before [dispose] frees the underlying
  /// resources. Prefer [dispose], which chains shutdown into cleanup.
  void shutdown() {
    _ensureAlive();
    NativeLibrary.instance.bindings.flm_manager_shutdown(_managerHandle);
  }

  /// Release every native resource this manager owns. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final bindings = NativeLibrary.instance.bindings;
    bindings.flm_manager_shutdown(_managerHandle);
    bindings.flm_manager_release(_managerHandle);
    await _lifecycleBridge.detach();
  }

  void _ensureAlive() {
    if (_disposed) {
      throw StateError('FoundryLocal has been disposed.');
    }
  }

  /// Internal accessor for the raw manager handle. Only used by sibling
  /// classes in this package.
  @visibleForTesting
  int get managerHandle => _managerHandle;
}

/// Enumeration of lifecycle events. Mirrors the C `flm_lifecycle_event`.
enum FlmLifecycleEventKind {
  foreground(raw.FlmLifecycleEvent.foreground),
  background(raw.FlmLifecycleEvent.background),
  memoryWarning(raw.FlmLifecycleEvent.memoryWarning),
  memoryCritical(raw.FlmLifecycleEvent.memoryCritical),
  lowPower(raw.FlmLifecycleEvent.lowPower),
  thermalThrottling(raw.FlmLifecycleEvent.thermalThrottling);

  const FlmLifecycleEventKind(this.code);
  final int code;
}
