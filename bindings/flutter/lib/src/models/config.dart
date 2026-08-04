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
    this.modelCacheDir,
    this.logsDir,
    this.logLevel,
    this.catalogUrls = const <String>[],
    this.catalogRegion,
    this.offline = false,
    this.maxConcurrentDownloads,
    this.downloadOnMeteredNetwork = false,
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

  final String? modelCacheDir;
  final String? logsDir;

  /// One of `verbose`, `debug`, `info`, `warning`, `error`, `fatal`, `off`.
  final String? logLevel;

  final List<String> catalogUrls;
  final String? catalogRegion;
  final bool offline;
  final int? maxConcurrentDownloads;
  final bool downloadOnMeteredNetwork;
  final bool autoUnloadOnBackground;

  /// 0 = derive from core count.
  final int? jobPoolThreads;

  final Map<String, Object?> additionalOptions;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'app_name': appName,
      if (appDataDir != null) 'app_data_dir': appDataDir,
      if (modelCacheDir != null) 'model_cache_dir': modelCacheDir,
      if (logsDir != null) 'logs_dir': logsDir,
      if (logLevel != null) 'log_level': logLevel,
      if (catalogUrls.isNotEmpty) 'catalog_urls': catalogUrls,
      if (catalogRegion != null) 'catalog_region': catalogRegion,
      'offline': offline,
      if (maxConcurrentDownloads != null)
        'max_concurrent_downloads': maxConcurrentDownloads,
      'download_on_metered_network': downloadOnMeteredNetwork,
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
    this.downloadOnMeteredNetwork,
    this.maxConcurrentDownloads,
    this.logLevel,
    this.autoUnloadOnBackground,
    this.offline,
  });

  final bool? downloadOnMeteredNetwork;
  final int? maxConcurrentDownloads;
  final String? logLevel;
  final bool? autoUnloadOnBackground;
  final bool? offline;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      if (downloadOnMeteredNetwork != null)
        'download_on_metered_network': downloadOnMeteredNetwork,
      if (maxConcurrentDownloads != null)
        'max_concurrent_downloads': maxConcurrentDownloads,
      if (logLevel != null) 'log_level': logLevel,
      if (autoUnloadOnBackground != null)
        'auto_unload_on_background': autoUnloadOnBackground,
      if (offline != null) 'offline': offline,
    };
  }

  String toJsonString() => jsonEncode(toJson());
}
