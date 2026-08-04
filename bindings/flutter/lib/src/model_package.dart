// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings/native_library.dart';
import 'error_capture.dart';
import 'model.dart';
import 'models/model_variant.dart';
import 'native_strings.dart';

/// A view of a [Model] that is known to be an ONNX Runtime model package.
///
/// Package handles delegate download / load / session state to their
/// **currently selected** variant. Call [selectBestVariant] first, or pin one
/// explicitly with [selectVariant].
class ModelPackage {
  ModelPackage.internal(this._model);

  final Model _model;

  /// Underlying model handle.
  Model get model => _model;

  int get _handle => _model.handle;

  /// The package manifest, scored against this device.
  ModelPackageManifest get manifest {
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

  /// Convenience: variants as a list, scored against this device.
  List<ModelVariant> get variants => manifest.variants;

  /// Currently selected variant id, or null when none has been chosen.
  String? get selectedVariantId => manifest.selectedVariantId;

  /// Pin the package to a specific variant. Subsequent [Model.download] /
  /// [Model.load] calls on this package act on it.
  void selectVariant(String variantId) {
    withCString(variantId, (ptr) {
      final status =
          NativeLibrary.instance.bindings.flm_package_select_variant(_handle, ptr);
      checkStatus(status, fallbackMessage: 'flm_package_select_variant failed');
    });
  }

  /// Let the SDK pick the best variant for this device. Returns the id of the
  /// variant that was chosen.
  String selectBestVariant({VariantSelectionConstraints? constraints}) {
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
    }
  }

  /// Obtain a standalone [Model] handle for one variant, so it can be
  /// downloaded / loaded / released independently of the package.
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
