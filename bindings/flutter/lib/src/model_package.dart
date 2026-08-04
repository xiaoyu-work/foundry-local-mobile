// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings/native_library.dart';
import 'error_capture.dart';
import 'model.dart';
import 'models/model_source.dart' show VariantConstraints;
import 'models/model_variant.dart';
import 'native_strings.dart';

/// A view of a [Model] that is known to be an ONNX Runtime model package.
///
/// Package handles delegate load / session state to their **currently
/// selected** variant. Prefer setting [VariantConstraints] on the
/// [ModelSource] so selection runs before any weights transfer; the
/// imperative [selectBestVariant] / [selectVariant] methods here are for
/// after-the-fact orchestration (offering the user a picker,
/// pre-provisioning several variants, running estimates before committing).
///
/// [manifest] and its convenience projections ([variants],
/// [selectedVariantId]) are cached after the first read to avoid two
/// costs: re-invoking `flm_package_get_variants_json` every time a caller
/// touches the property, and the correctness hazard of two consecutive
/// reads returning subtly different snapshots when a
/// [selectVariant]/[selectBestVariant] call has run in between. Any
/// selection call automatically invalidates the cache; a caller who wants
/// to force a re-read for any other reason can call [refresh].
class ModelPackage {
  ModelPackage.internal(this._model);

  final Model _model;

  ModelPackageManifest? _cachedManifest;

  /// Underlying model handle.
  Model get model => _model;

  int get _handle => _model.handle;

  /// The package manifest, scored against this device.
  ///
  /// Cached on first read. Any [selectVariant] or [selectBestVariant]
  /// call invalidates the cache. Use [refresh] to force a fresh decode.
  ModelPackageManifest get manifest =>
      _cachedManifest ??= _decodeManifest();

  ModelPackageManifest _decodeManifest() {
    final bindings = NativeLibrary.instance.bindings;
    final out = calloc<Pointer<Char>>();
    try {
      final status = bindings.flm_package_get_variants_json(_handle, out);
      checkStatus(status,
          fallbackMessage: 'flm_package_get_variants_json failed');
      try {
        final s = takeOutString(out.value);
        return ModelPackageManifest.fromJson(
            jsonDecode(s) as Map<String, Object?>);
      } finally {
        bindings.flm_string_free(out.value);
      }
    } finally {
      calloc.free(out);
    }
  }

  /// Drop the cached manifest and decode it again from the ABI on the next
  /// read. The selection methods on this class already invalidate the
  /// cache, so you do not need to call [refresh] after them.
  ///
  /// Note what this does **not** do. The core scans the package directory
  /// once, when the model handle first resolves a package, and keeps that
  /// snapshot until the model is deleted; `flm_package_get_variants_json`
  /// re-serialises it rather than re-reading the disk. So [refresh] gives
  /// you a fresh decode of the *same* snapshot — it cannot observe files
  /// that appeared underneath, and [ModelVariant.isCached] and
  /// [ModelVariant.downloadSizeBytes] will not move because a download
  /// finished elsewhere. To see acquisition that happened outside this
  /// object, get a new model handle from the manager.
  void refresh() {
    _cachedManifest = null;
  }

  /// Convenience: variants as a list, scored against this device. Backed
  /// by the same cached [manifest].
  List<ModelVariant> get variants => manifest.variants;

  /// Currently selected variant id, or null when none has been chosen.
  /// Backed by the same cached [manifest].
  String? get selectedVariantId => manifest.selectedVariantId;

  /// Pin the package to a specific variant. Subsequent [Model.load] calls
  /// on this package act on it. Invalidates the cached [manifest].
  void selectVariant(String variantId) {
    withCString(variantId, (ptr) {
      final status =
          NativeLibrary.instance.bindings.flm_package_select_variant(_handle, ptr);
      checkStatus(status, fallbackMessage: 'flm_package_select_variant failed');
    });
    _cachedManifest = null;
  }

  /// Let the SDK pick the best variant for this device. Returns the id of the
  /// variant that was chosen. Invalidates the cached [manifest].
  String selectBestVariant({VariantConstraints? constraints}) {
    final bindings = NativeLibrary.instance.bindings;
    final constraintsJson = constraints == null
        ? null
        : jsonEncode(constraints.toJson());
    final out = calloc<Pointer<Char>>();
    try {
      return withNullableCString(constraintsJson, (constraintsPtr) {
        final status = bindings.flm_package_select_best_variant(
            _handle, constraintsPtr, out);
        checkStatus(status,
            fallbackMessage: 'flm_package_select_best_variant failed');
        try {
          return takeOutString(out.value);
        } finally {
          bindings.flm_string_free(out.value);
        }
      });
    } finally {
      calloc.free(out);
      _cachedManifest = null;
    }
  }

  /// Obtain a standalone [Model] handle for one variant, so it can be
  /// loaded / released independently of the package.
  Model getVariant(String variantId) {
    final bindings = NativeLibrary.instance.bindings;
    final out = calloc<Uint64>();
    try {
      return withCString(variantId, (ptr) {
        final status = bindings.flm_package_get_variant(_handle, ptr, out);
        checkStatus(status, fallbackMessage: 'flm_package_get_variant failed');
        return Model.fromHandle(out.value);
      });
    } finally {
      calloc.free(out);
    }
  }

  /// Estimate the transfer for a set of variants (or the currently selected
  /// variant when [variantIds] is null).
  DownloadEstimate estimateDownload({List<String>? variantIds}) {
    final bindings = NativeLibrary.instance.bindings;
    final json = variantIds == null ? null : jsonEncode(variantIds);
    final out = calloc<Pointer<Char>>();
    try {
      return withNullableCString(json, (jsonPtr) {
        final status = bindings.flm_package_estimate_download_json(
            _handle, jsonPtr, out);
        checkStatus(status,
            fallbackMessage: 'flm_package_estimate_download_json failed');
        try {
          final s = takeOutString(out.value);
          return DownloadEstimate.fromJson(
              jsonDecode(s) as Map<String, Object?>);
        } finally {
          bindings.flm_string_free(out.value);
        }
      });
    } finally {
      calloc.free(out);
    }
  }
}
