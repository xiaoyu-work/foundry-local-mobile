// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:convert';

import 'package:meta/meta.dart';

/// Configuration passed to [FoundryLocal.create]. Serialized straight to the
/// JSON schema documented on `flm_manager_create`.
@immutable
class FoundryLocalConfig {
  const FoundryLocalConfig({
    required this.appName,
    this.appDataDir,
    this.logLevel,
    this.autoUnloadOnBackground = true,
    this.jobPoolThreads,
    this.additionalOptions = const <String, Object?>{},
  });

  /// Non-empty app identifier used for cache namespacing and logs.
  final String appName;

  /// Sandbox path resolved from the platform. When null, the plugin fills this
  /// in from `getApplicationSupportDirectory` before calling the C ABI, because
  /// the core requires it on mobile.
  final String? appDataDir;

  /// One of `verbose`, `debug`, `info`, `warning`, `error`, `fatal`, `off`.
  final String? logLevel;

  final bool autoUnloadOnBackground;

  /// 0 = derive from core count.
  final int? jobPoolThreads;

  final Map<String, Object?> additionalOptions;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'app_name': appName,
      if (appDataDir != null) 'app_data_dir': appDataDir,
      if (logLevel != null) 'log_level': logLevel,
      'auto_unload_on_background': autoUnloadOnBackground,
      if (jobPoolThreads != null) 'job_pool_threads': jobPoolThreads,
      if (additionalOptions.isNotEmpty)
        'additional_options': additionalOptions,
    };
  }

  String toJsonString() => jsonEncode(toJson());
}

/// Mutable subset of [FoundryLocalConfig] accepted by
/// `flm_manager_update_settings`.
@immutable
class RuntimeSettings {
  const RuntimeSettings({
    this.logLevel,
    this.autoUnloadOnBackground,
  });

  final String? logLevel;
  final bool? autoUnloadOnBackground;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      if (logLevel != null) 'log_level': logLevel,
      if (autoUnloadOnBackground != null)
        'auto_unload_on_background': autoUnloadOnBackground,
    };
  }

  String toJsonString() => jsonEncode(toJson());
}
