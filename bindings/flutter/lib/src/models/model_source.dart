// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:convert';

import 'package:meta/meta.dart';

import 'device_profile.dart';

/// How an app hands the SDK a model of its own — either bundled into the app
/// binary or hosted on remote storage. Serialized to the `source_json` schema
/// documented on `flm_manager_add_model_source_async`.
@immutable
sealed class ModelSource {
  const ModelSource({required this.name, this.constraints});

  /// Name the model is registered under. Used later as an alias for lookup.
  final String name;

  /// Optional per-source constraints applied when the source is a package.
  final ModelSourceConstraints? constraints;

  Map<String, Object?> toJson();
  String toJsonString() => jsonEncode(toJson());

  factory ModelSource.bundled({
    required String name,
    required String path,
    bool copyIntoCache = false,
    ModelSourceConstraints? constraints,
  }) =>
      BundledModelSource(
        name: name,
        path: path,
        copyIntoCache: copyIntoCache,
        constraints: constraints,
      );

  factory ModelSource.remote({
    required String name,
    required String url,
    Map<String, String> headers = const <String, String>{},
    ModelSourceConstraints? constraints,
  }) =>
      RemoteModelSource(
        name: name,
        url: url,
        headers: headers,
        constraints: constraints,
      );
}

/// A model shipped inside the app, sitting at a filesystem path the caller
/// controls. Loaded in place by default.
@immutable
class BundledModelSource extends ModelSource {
  const BundledModelSource({
    required super.name,
    required this.path,
    this.copyIntoCache = false,
    super.constraints,
  });

  final String path;

  /// When true the core copies the files into the model cache before loading,
  /// which is useful when [path] is a temporary extraction directory the OS
  /// can evict.
  final bool copyIntoCache;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'kind': 'bundled',
        'name': name,
        'path': path,
        if (copyIntoCache) 'copy_into_cache': true,
        if (constraints != null) 'constraints': constraints!.toJson(),
      };
}

/// A model hosted on remote storage. The SDK does not perform HTTP itself:
/// the request goes through the installed transport.
@immutable
class RemoteModelSource extends ModelSource {
  const RemoteModelSource({
    required super.name,
    required this.url,
    this.headers = const <String, String>{},
    super.constraints,
  });

  final String url;

  /// Sent with every request the transport makes for this source.
  ///
  /// `headers` covers the common credential setups (SAS URL query string,
  /// bearer token, API key). Tokens that must be refreshed part-way through a
  /// multi-gigabyte download belong in the transport itself, not here.
  final Map<String, String> headers;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'kind': 'remote',
        'name': name,
        'url': url,
        if (headers.isNotEmpty) 'headers': headers,
        if (constraints != null) 'constraints': constraints!.toJson(),
      };
}

/// Cross-platform policy the SDK applies when selecting a variant of a package
/// source.
@immutable
class ModelSourceConstraints {
  const ModelSourceConstraints({
    this.maxDownloadBytes,
    this.allowedDevices,
    this.preferSmallest = false,
  });

  final int? maxDownloadBytes;
  final List<FlmDevice>? allowedDevices;
  final bool preferSmallest;

  Map<String, Object?> toJson() => <String, Object?>{
        if (maxDownloadBytes != null) 'max_download_bytes': maxDownloadBytes,
        if (allowedDevices != null)
          'allowed_devices': allowedDevices!.map((d) => d.name).toList(),
        if (preferSmallest) 'prefer_smallest': preferSmallest,
      };
}

/// Result reported when a model source has been resolved and any required
/// download has finished.
@immutable
class ModelSourceResult {
  const ModelSourceResult({
    required this.name,
    required this.path,
    required this.variantId,
    required this.bytesDownloaded,
    required this.bytesReused,
    required this.wasCached,
  });

  final String name;
  final String path;
  final String? variantId;
  final int bytesDownloaded;
  final int bytesReused;
  final bool wasCached;

  factory ModelSourceResult.fromJson(Map<String, Object?> json) =>
      ModelSourceResult(
        name: json['name'] as String? ?? '',
        path: json['path'] as String? ?? '',
        variantId: json['variant_id'] as String?,
        bytesDownloaded: (json['bytes_downloaded'] as num?)?.toInt() ?? 0,
        bytesReused: (json['bytes_reused'] as num?)?.toInt() ?? 0,
        wasCached: json['was_cached'] as bool? ?? false,
      );
}
