// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:convert';

import 'package:meta/meta.dart';

import '../model.dart';
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

  /// Name the model is registered under, and the thing that decides whether it
  /// can run. The runtime picks a session implementation from the model's task,
  /// and it learns tasks from the Foundry Local catalog. Name the source after
  /// the catalog model it actually is — say
  /// `qwen2.5-0.5b-instruct-generic-cpu:4` rather than `my-model` — and the task
  /// comes with it. A name the catalog has never seen still downloads, installs
  /// and loads, but creating a session on it will fail.
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

  /// When true the core copies the files into the model cache before loading.
  /// The default links to [path] instead, so the app keeps owning those files
  /// and must keep them where they are. Copy when it cannot promise that —
  /// a temporary extraction directory, or an OS cache that can be evicted.
  /// For a package only the selected variant is copied.
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

/// Outcome of a successful [FoundryLocal.addModelSource]. The files are on
/// disk at [path] regardless of whether [model] is populated.
///
/// [model] is a ready-to-use handle the core minted inside the same
/// acquisition job (via the `model_handle` field on
/// `flm_manager_add_model_source_async`'s completion result). It is `null`
/// when Foundry Local had already scanned the device for models before this
/// source was added: that scan runs once, on the first catalog query of the
/// process, and cannot be repeated, so the model stays invisible for this
/// run and looking it up by [name] fails for the same reason.
/// [handleUnavailableReason] says so in words. Add model sources before
/// querying the catalog and the case does not arise; the files at [path] are
/// committed regardless and the next launch picks them up. The null case is
/// **not** an error, so it is surfaced here rather than thrown.
///
/// Callers that add their sources first — the documented order — should
/// prefer [requireModel] rather than paying null-handling ceremony for an
/// outcome they have designed out. Callers that want to handle it explicitly
/// should read [model] directly.
@immutable
class ModelSourceResult {
  const ModelSourceResult({
    required this.name,
    required this.path,
    required this.variantId,
    required this.bytesDownloaded,
    required this.bytesReused,
    required this.wasCached,
    required this.model,
    this.handleUnavailableReason,
  });

  /// Alias the source registered under. Same value the caller passed on
  /// [ModelSource.name].
  final String name;

  /// Absolute on-disk path of the resolved model.
  final String path;

  /// For a package source, the id of the variant that was chosen; `null`
  /// (empty string on the wire) for a flat model.
  final String? variantId;

  /// Bytes actually transferred by the transport.
  final int bytesDownloaded;

  /// Bytes served from an already-on-disk copy or from another variant's
  /// shared assets — never fetched over the wire.
  final int bytesReused;

  /// Whether the whole source was resolved from cache, without any transfer.
  final bool wasCached;

  /// Ready-to-use model handle for the acquired model, or `null` in the
  /// handle-less case described in the class-level Dartdoc.
  final Model? model;

  /// Why [model] is `null`, straight from the core. `null` when [model] is
  /// present.
  final String? handleUnavailableReason;

  /// Return [model] when the core surfaced a handle, and throw a
  /// [StateError] otherwise.
  ///
  /// The throw message names both [name] and [path] and carries the core's
  /// own explanation, so a caller staring at the stack trace can tell at a
  /// glance that the download succeeded and what to change.
  ///
  /// Prefer reading [model] directly when the caller wants to handle the
  /// null case (showing a "restart to finish setup" prompt, or reporting
  /// telemetry).
  Model requireModel() {
    final m = model;
    if (m != null) return m;
    throw StateError(
      'Model source "$name" was added successfully — files are on disk at '
      '"$path" — but no handle came back: '
      '${handleUnavailableReason ?? 'the catalog did not surface one.'}',
    );
  }
}
