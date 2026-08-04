// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import 'bindings/bindings.dart' as raw;
import 'bindings/native_library.dart';
import 'error_capture.dart';
import 'job_runner.dart';
import 'model.dart';
import 'models/model_info.dart';
import 'native_strings.dart';

/// Filter accepted by [Catalog.listModels].
class CatalogFilter {
  const CatalogFilter({
    this.task,
    this.cachedOnly = false,
    this.loadedOnly = false,
    this.maxSizeBytes,
    this.compatibleOnly = true,
  });

  final String? task;
  final bool cachedOnly;
  final bool loadedOnly;
  final int? maxSizeBytes;
  final bool compatibleOnly;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      if (task != null) 'task': task,
      if (cachedOnly) 'cached_only': cachedOnly,
      if (loadedOnly) 'loaded_only': loadedOnly,
      if (maxSizeBytes != null) 'max_size_bytes': maxSizeBytes,
      'compatible_only': compatibleOnly,
    };
  }
}

/// The model catalog. Handle is borrowed from the manager and remains valid
/// for the manager's lifetime; there is no explicit release.
class Catalog {
  /// Internal constructor — call [FoundryLocal.catalog] to get an instance.
  @internal
  Catalog.internal(this._handle);

  final int _handle;

  /// List models. When [filter] is null every catalog entry is returned; a
  /// filter restricts the result to models the device can run.
  Future<List<ModelInfo>> listModels({CatalogFilter? filter}) async {
    final bindings = NativeLibrary.instance.bindings;
    final filterJson = filter == null ? null : jsonEncode(filter.toJson());

    final result = await withNullableCString<Future<Map<String, Object?>>>(
      filterJson,
      (filterPtr) => runSimpleJob(
        (completionPtr, userData, outJob) => bindings
            .flm_catalog_list_models_async(
                _handle, filterPtr, completionPtr, userData, outJob),
      ),
    );
    final list = (result['models'] as List?)?.cast<Map<String, Object?>>() ??
        const <Map<String, Object?>>[];
    return list.map(ModelInfo.fromJson).toList(growable: false);
  }

  /// Resolve a model by alias (`qwen2.5-0.5b`). This may hit the network to
  /// resolve the alias if the catalog has not been fetched yet.
  Future<Model> getModel(String alias) async {
    final bindings = NativeLibrary.instance.bindings;
    final result = await withCString<Future<Map<String, Object?>>>(
      alias,
      (aliasPtr) => runSimpleJob(
        (completionPtr, userData, outJob) => bindings
            .flm_catalog_get_model_async(
                _handle, aliasPtr, completionPtr, userData, outJob),
      ),
    );
    final handle = (result['model_handle'] as num?)?.toInt() ?? 0;
    if (handle == raw.FLM_INVALID_HANDLE) {
      throw StateError(
          'Catalog returned an invalid model handle for alias "$alias".');
    }
    return Model.fromHandle(handle);
  }

  /// Resolve a specific variant by its full id, bypassing automatic selection.
  Future<Model> getModelById(String modelId) async {
    final bindings = NativeLibrary.instance.bindings;
    final result = await withCString<Future<Map<String, Object?>>>(
      modelId,
      (idPtr) => runSimpleJob(
        (completionPtr, userData, outJob) => bindings
            .flm_catalog_get_model_by_id_async(
                _handle, idPtr, completionPtr, userData, outJob),
      ),
    );
    final handle = (result['model_handle'] as num?)?.toInt() ?? 0;
    if (handle == raw.FLM_INVALID_HANDLE) {
      throw StateError(
          'Catalog returned an invalid model handle for id "$modelId".');
    }
    return Model.fromHandle(handle);
  }

  /// Models already present in the local cache. Serves from disk, so it is
  /// safe to call during startup before any network is available.
  List<ModelInfo> listCachedModels() {
    final bindings = NativeLibrary.instance.bindings;
    final out = calloc<Pointer<Char>>();
    try {
      final status =
          bindings.flm_catalog_list_cached_models_json(_handle, out);
      checkStatus(status,
          fallbackMessage: 'flm_catalog_list_cached_models_json failed');
      try {
        final s = takeOutString(out.value);
        if (s.isEmpty) return const <ModelInfo>[];
        final decoded = jsonDecode(s);
        final list =
            (decoded is List ? decoded : (decoded as Map)['models'] as List?);
        return (list ?? const <Object?>[])
            .cast<Map<String, Object?>>()
            .map(ModelInfo.fromJson)
            .toList(growable: false);
      } finally {
        bindings.flm_string_free(out.value);
      }
    } finally {
      calloc.free(out);
    }
  }

  /// Bytes currently consumed by the model cache.
  int get cacheSizeBytes {
    final bindings = NativeLibrary.instance.bindings;
    final out = calloc<Int64>();
    try {
      final status =
          bindings.flm_catalog_get_cache_size_bytes(_handle, out);
      checkStatus(status,
          fallbackMessage: 'flm_catalog_get_cache_size_bytes failed');
      return out.value;
    } finally {
      calloc.free(out);
    }
  }
}
