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
  const ModelSource({
    required this.name,
    this.constraints,
    this.resume = true,
    this.verifyChecksums = true,
  });

  /// Name the model is registered under. Used later as an alias for lookup.
  final String name;

  /// Cross-platform variant policy for a package source (see
  /// [VariantConstraints]). Applied by the core against the manifest
  /// **before** any weights transfer, so a phone never spends bytes on a
  /// variant it cannot run. Prefer this to the imperative
  /// [ModelPackage.selectBestVariant] path — it saves the wrong download.
  ///
  /// Ignored on non-package models.
  final VariantConstraints? constraints;

  /// Whether an interrupted download resumes from the last written byte or
  /// starts over. Defaults to true. Turn it off when the origin server is
  /// known to mishandle `Range` requests — that is fatal on a multi-GB
  /// download that keeps hitting network transitions.
  final bool resume;

  /// Whether each downloaded file is verified against the SHA-256 in the
  /// manifest. Defaults to true and should stay on: a model from a remote
  /// URL is untrusted input the runtime will `mmap` and execute operators
  /// from. Turning this off is only ever right for local development
  /// against an unstable manifest.
  final bool verifyChecksums;

  Map<String, Object?> toJson();
  String toJsonString() => jsonEncode(toJson());

  /// Common fields shared by every source kind. Subclasses spread this into
  /// their JSON before adding their own keys.
  @protected
  Map<String, Object?> commonJson() => <String, Object?>{
        'name': name,
        if (constraints != null) 'constraints': constraints!.toJson(),
        if (!resume) 'resume': false,
        if (!verifyChecksums) 'verify_checksums': false,
      };

  factory ModelSource.bundled({
    required String name,
    required String path,
    bool copyIntoCache = false,
    VariantConstraints? constraints,
    bool resume = true,
    bool verifyChecksums = true,
  }) =>
      BundledModelSource(
        name: name,
        path: path,
        copyIntoCache: copyIntoCache,
        constraints: constraints,
        resume: resume,
        verifyChecksums: verifyChecksums,
      );

  factory ModelSource.remote({
    required String name,
    required String url,
    Map<String, String> headers = const <String, String>{},
    VariantConstraints? constraints,
    bool resume = true,
    bool verifyChecksums = true,
  }) =>
      RemoteModelSource(
        name: name,
        url: url,
        headers: headers,
        constraints: constraints,
        resume: resume,
        verifyChecksums: verifyChecksums,
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
    super.resume,
    super.verifyChecksums,
  });

  final String path;

  /// When true the core copies the files into the model cache before loading,
  /// which is useful when [path] is a temporary extraction directory the OS
  /// can evict.
  final bool copyIntoCache;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'kind': 'bundled',
        ...commonJson(),
        'path': path,
        if (copyIntoCache) 'copy_into_cache': true,
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
    super.resume,
    super.verifyChecksums,
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
        ...commonJson(),
        'url': url,
        if (headers.isNotEmpty) 'headers': headers,
      };
}

/// Cross-platform variant policy for a model package.
///
/// Applied by `flm_package_select_best_variant` when calling it explicitly
/// on a [ModelPackage], and — more importantly for cross-platform apps —
/// honoured by [FoundryLocal.addModelSource] when set on the [ModelSource]
/// itself: the scoring runs against the manifest **before** any weights
/// transfer, so a phone never spends bytes on a QNN build it has no NPU for
/// or a CoreML variant it has no Apple Neural Engine for.
///
/// The four fields below are the entire declarative surface the core
/// honours. Extra fields would be silently ignored, so this class does not
/// carry any.
@immutable
class VariantConstraints {
  const VariantConstraints({
    this.maxDownloadBytes,
    this.allowedDevices,
    this.preferSmallest = false,
    this.requireCached = false,
  });

  /// Skip any variant whose selected files would exceed this many bytes on
  /// the wire.
  final int? maxDownloadBytes;

  /// Restrict placement to these devices. `null` and an empty list both
  /// mean "any device"; set only when the app must force, e.g., NPU-only.
  final List<FlmDevice>? allowedDevices;

  /// Break ties on download size rather than the compatibility score. Off
  /// by default — the compatibility score already rewards native placements
  /// (NPU over GPU over CPU) which is what most apps actually want.
  final bool preferSmallest;

  /// Only consider variants whose files are already on disk. Useful for an
  /// offline path or a "no more downloads" preference in a UI. Combined
  /// with [maxDownloadBytes] you get "run something now, without paying".
  final bool requireCached;

  Map<String, Object?> toJson() => <String, Object?>{
        if (maxDownloadBytes != null) 'max_download_bytes': maxDownloadBytes,
        if (allowedDevices != null)
          'allowed_devices': allowedDevices!.map((d) => d.name).toList(),
        if (preferSmallest) 'prefer_smallest': preferSmallest,
        if (requireCached) 'require_cached': requireCached,
      };
}

/// Result reported when a model source has been resolved and any required
/// download has finished. Read from `flm_job_take_result_json` on the job
/// returned by `flm_manager_add_model_source_async`.
@immutable
class ModelSourceResult {
  const ModelSourceResult({
    required this.name,
    required this.path,
    required this.variantId,
    required this.bytesDownloaded,
    required this.bytesReused,
    required this.wasCached,
    required this.modelHandle,
  });

  /// Alias the source registered under.
  final String name;

  /// Absolute on-disk path of the resolved model.
  final String path;

  /// For a package source, the id of the variant that was chosen; `null`
  /// (an empty string in the wire schema) for a flat model.
  final String? variantId;

  /// Bytes actually transferred by the transport.
  final int bytesDownloaded;

  /// Bytes served from an already-on-disk copy or from another variant's
  /// shared assets — never fetched over the wire.
  final int bytesReused;

  /// Whether the whole source was resolved from cache, without any transfer.
  final bool wasCached;

  /// A ready-to-use `flm_model` handle. `null` in the unexpected case where
  /// the core reports `FLM_INVALID_HANDLE` — the download itself still
  /// succeeded (`path` and byte counters are set); the caller can recover by
  /// looking the model up through [Catalog.getModel] using [name].
  final int? modelHandle;

  factory ModelSourceResult.fromJson(Map<String, Object?> json) {
    final rawHandle = (json['model_handle'] as num?)?.toInt();
    final handle = (rawHandle == null || rawHandle == 0) ? null : rawHandle;
    final rawVariant = json['variant_id'] as String?;
    return ModelSourceResult(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      variantId: (rawVariant == null || rawVariant.isEmpty) ? null : rawVariant,
      bytesDownloaded: (json['bytes_downloaded'] as num?)?.toInt() ?? 0,
      bytesReused: (json['bytes_reused'] as num?)?.toInt() ?? 0,
      wasCached: json['was_cached'] as bool? ?? false,
      modelHandle: handle,
    );
  }
}
