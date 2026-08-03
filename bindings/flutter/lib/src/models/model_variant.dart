// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'package:meta/meta.dart';

import 'device_profile.dart';

/// One build variant of a model package. Populated from the JSON array
/// returned by `flm_package_get_variants_json`.
@immutable
class ModelVariant {
  const ModelVariant({
    required this.id,
    required this.component,
    required this.executionProvider,
    required this.device,
    required this.compatibilityString,
    required this.platform,
    required this.downloadSizeBytes,
    required this.diskSizeBytes,
    required this.sharedAssetRefs,
    required this.isCompatible,
    required this.compatibilityScore,
    required this.isCached,
    this.incompatibilityReason,
    this.raw = const <String, Object?>{},
  });

  final String id;
  final String component;
  final String executionProvider;
  final FlmDevice device;
  final String compatibilityString;

  /// One of `android`, `ios`, `windows`, `linux`, `macos`, `any`.
  final String platform;

  /// Bytes the caller would have to transfer, taking already-cached shared
  /// assets into account.
  final int downloadSizeBytes;

  /// Bytes this variant occupies on disk once installed.
  final int diskSizeBytes;

  final List<String> sharedAssetRefs;
  final bool isCompatible;
  final int compatibilityScore;
  final bool isCached;
  final String? incompatibilityReason;
  final Map<String, Object?> raw;

  factory ModelVariant.fromJson(Map<String, Object?> json) {
    return ModelVariant(
      id: json['id'] as String? ?? '',
      component: json['component'] as String? ?? 'model',
      executionProvider: json['execution_provider'] as String? ?? '',
      device: FlmDevice.fromJson(json['device']),
      compatibilityString: json['compatibility_string'] as String? ?? '',
      platform: json['platform'] as String? ?? 'any',
      downloadSizeBytes: (json['download_size_bytes'] as num?)?.toInt() ?? 0,
      diskSizeBytes: (json['disk_size_bytes'] as num?)?.toInt() ?? 0,
      sharedAssetRefs:
          (json['shared_asset_refs'] as List?)?.cast<String>() ?? const <String>[],
      isCompatible: json['is_compatible'] as bool? ?? false,
      compatibilityScore:
          (json['compatibility_score'] as num?)?.toInt() ?? 0,
      isCached: json['is_cached'] as bool? ?? false,
      incompatibilityReason: json['incompatibility_reason'] as String?,
      raw: json,
    );
  }
}

/// Top-level result of `flm_package_get_variants_json`.
@immutable
class ModelPackageManifest {
  const ModelPackageManifest({
    required this.packageId,
    required this.schemaVersion,
    required this.selectedVariantId,
    required this.sharedAssetsBytes,
    required this.variants,
    this.raw = const <String, Object?>{},
  });

  final String packageId;
  final String schemaVersion;
  final String? selectedVariantId;
  final int sharedAssetsBytes;
  final List<ModelVariant> variants;
  final Map<String, Object?> raw;

  factory ModelPackageManifest.fromJson(Map<String, Object?> json) {
    return ModelPackageManifest(
      packageId: json['package_id'] as String? ?? '',
      schemaVersion: json['schema_version'] as String? ?? '',
      selectedVariantId: json['selected_variant_id'] as String?,
      sharedAssetsBytes: (json['shared_assets_bytes'] as num?)?.toInt() ?? 0,
      variants: (json['variants'] as List?)
              ?.cast<Map<String, Object?>>()
              .map(ModelVariant.fromJson)
              .toList(growable: false) ??
          const <ModelVariant>[],
      raw: json,
    );
  }
}

/// Result of `flm_package_estimate_download_json`.
@immutable
class DownloadEstimate {
  const DownloadEstimate({
    required this.downloadBytes,
    required this.diskBytes,
    required this.alreadyCachedBytes,
    required this.availableStorageBytes,
    required this.fitsOnDevice,
  });

  final int downloadBytes;
  final int diskBytes;
  final int alreadyCachedBytes;
  final int availableStorageBytes;
  final bool fitsOnDevice;

  factory DownloadEstimate.fromJson(Map<String, Object?> json) => DownloadEstimate(
        downloadBytes: (json['download_bytes'] as num?)?.toInt() ?? 0,
        diskBytes: (json['disk_bytes'] as num?)?.toInt() ?? 0,
        alreadyCachedBytes:
            (json['already_cached_bytes'] as num?)?.toInt() ?? 0,
        availableStorageBytes:
            (json['available_storage_bytes'] as num?)?.toInt() ?? 0,
        fitsOnDevice: json['fits_on_device'] as bool? ?? false,
      );
}

/// Optional constraints passed to `flm_package_select_best_variant`.
@immutable
class VariantSelectionConstraints {
  const VariantSelectionConstraints({
    this.maxDownloadBytes,
    this.allowedDevices,
    this.preferSmallest = false,
  });

  final int? maxDownloadBytes;
  final List<FlmDevice>? allowedDevices;
  final bool preferSmallest;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      if (maxDownloadBytes != null) 'max_download_bytes': maxDownloadBytes,
      if (allowedDevices != null)
        'allowed_devices': allowedDevices!.map((d) => d.name).toList(),
      if (preferSmallest) 'prefer_smallest': preferSmallest,
    };
  }
}
