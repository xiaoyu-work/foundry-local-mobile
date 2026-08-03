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
import 'catalog.dart';
import 'error_capture.dart';
import 'job_runner.dart';
import 'lifecycle.dart';
import 'model.dart';
import 'models/config.dart';
import 'models/device_profile.dart';
import 'models/model_source.dart';
import 'models/progress.dart';
import 'native_strings.dart';
import 'transport.dart';

/// Root object of the SDK. Owns the manager handle, the catalog, the
/// transport registration and the app-lifecycle bridge; released by [dispose].
class FoundryLocal {
  FoundryLocal._({
    required this.config,
    required int managerHandle,
    required int catalogHandle,
    required this.transport,
    required TransportRegistration? transportRegistration,
    required LifecycleBridge lifecycleBridge,
  })  : _managerHandle = managerHandle,
        _transportRegistration = transportRegistration,
        _lifecycleBridge = lifecycleBridge,
        catalog = Catalog._(catalogHandle);

  /// Configuration this instance was created with. Read-only after creation.
  final FoundryLocalConfig config;

  /// The HTTP transport that will service every remote download. Installed at
  /// creation and released when this instance is disposed.
  final FlmTransport transport;

  /// Model catalog. Shares the manager's lifetime; do not release explicitly.
  final Catalog catalog;

  final int _managerHandle;
  final TransportRegistration? _transportRegistration;
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

  /// Whether the Foundry Local runtime is present and loadable.
  static bool get isRuntimeAvailable =>
      NativeLibrary.instance.bindings.flm_is_runtime_available() != 0;

  /// Create a manager.
  ///
  /// The plugin fills in `app_data_dir` from `getApplicationSupportDirectory`
  /// unless the caller sets it explicitly, because the core requires a sandbox
  /// path on mobile.
  ///
  /// A [FlmTransport] can be supplied; when omitted, [DartHttpTransport] is
  /// installed. Even apps that do not intend to use remote sources should let
  /// this default in — the transport is also used to fetch model manifests
  /// from the app's own storage.
  static Future<FoundryLocal> create(
    FoundryLocalConfig config, {
    FlmTransport? transport,
  }) async {
    final bindings = NativeLibrary.instance.bindings;

    // Fill in app_data_dir from the platform if the caller did not.
    var resolvedConfig = config;
    if (config.appDataDir == null) {
      final dir = await pp.getApplicationSupportDirectory();
      resolvedConfig = FoundryLocalConfig(
        appName: config.appName,
        appDataDir: dir.path,
        modelCacheDir: config.modelCacheDir,
        logsDir: config.logsDir,
        logLevel: config.logLevel,
        catalogUrls: config.catalogUrls,
        catalogRegion: config.catalogRegion,
        offline: config.offline,
        maxConcurrentDownloads: config.maxConcurrentDownloads,
        downloadOnMeteredNetwork: config.downloadOnMeteredNetwork,
        autoUnloadOnBackground: config.autoUnloadOnBackground,
        jobPoolThreads: config.jobPoolThreads,
        additionalOptions: config.additionalOptions,
      );
    }

    // Install the transport BEFORE creating the manager. The core caches the
    // installed transport at manager creation time.
    final FlmTransport effectiveTransport = transport ?? DartHttpTransport();
    TransportRegistration? registration;
    try {
      registration = installTransport(effectiveTransport);
    } on StateError {
      // Another transport is already installed; carry on. The caller is
      // responsible for that setup.
      registration = null;
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

    final catalogOut = calloc<Uint64>();
    late int catalogHandle;
    try {
      final status =
          bindings.flm_manager_get_catalog(managerHandle, catalogOut);
      checkStatus(status,
          fallbackMessage: 'flm_manager_get_catalog failed');
      catalogHandle = catalogOut.value;
    } finally {
      calloc.free(catalogOut);
    }

    final lifecycleBridge = LifecycleBridge.attach(managerHandle);

    final foundry = FoundryLocal._(
      config: resolvedConfig,
      managerHandle: managerHandle,
      catalogHandle: catalogHandle,
      transport: effectiveTransport,
      transportRegistration: registration,
      lifecycleBridge: lifecycleBridge,
    );
    return foundry;
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

  /// Register a bundled or remote model source with the manager. Downloads
  /// (for remote sources) run through the installed transport.
  ///
  /// Returns the resolved [Model] handle for the source. Progress events for
  /// the download (or the resolve, for a bundled source) are delivered via
  /// [onProgress] if provided.
  Future<Model> addModelSource(
    ModelSource source, {
    void Function(Progress)? onProgress,
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
        source.toJsonString(),
        (sourcePtr) => runProgressJob(
          abiCall: (progressPtr, completionPtr, userDataPtr, outJob) =>
              bindings.flm_manager_add_model_source_async(
            _managerHandle,
            sourcePtr,
            progressPtr,
            completionPtr,
            userDataPtr,
            outJob,
          ),
          onProgress: sink,
        ),
      );

      // The core writes the resolved alias back into the result; we then
      // look up the handle via the catalog by that name.
      final resolved = ModelSourceResult.fromJson(result);
      return catalog.getModel(resolved.name);
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
    await _transportRegistration?.close();
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
  thermalThrottling(raw.FlmLifecycleEvent.thermalThrottling),
  networkMetered(raw.FlmLifecycleEvent.networkMetered),
  networkUnmetered(raw.FlmLifecycleEvent.networkUnmetered);

  const FlmLifecycleEventKind(this.code);
  final int code;
}
