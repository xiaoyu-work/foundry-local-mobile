// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import Foundation
import FoundryLocalMobile

/// Read-only view of the model catalog. Obtained from ``FoundryLocal/catalog``.
///
/// Catalog handles are borrowed from the owning ``FoundryLocal``: releasing them is a
/// no-op, and they become invalid when the manager is released.
public final class Catalog: @unchecked Sendable {
    public let handle: flm_catalog

    init(handle: flm_catalog) {
        self.handle = handle
    }

    /// List catalog models, optionally filtered.
    public func listModels(_ filter: CatalogFilter = .init()) async throws -> [ModelInfo] {
        let filterJSON = filter.encodeAsJSON()
        return try await runAsyncJob(
            decode: { job in
                let json = try takeJobResultJSON(job)
                return try flmJSONDecoder.decode(CatalogListResult.self, from: Data(json.utf8)).models
            },
            submit: { [handle] userData, _, onComplete, outJob in
                filterJSON.withCString { filterPtr in
                    flm_catalog_list_models_async(handle, filterPtr, onComplete, userData, outJob)
                }
            }
        )
    }

    /// Resolve a model by its catalog alias (e.g. `"qwen2.5-0.5b"`). For a package
    /// this returns the package handle, not any specific variant.
    public func model(alias: String) async throws -> Model {
        try await runAsyncJob(
            decode: { job in
                let json = try takeJobResultJSON(job)
                let parsed = try flmJSONDecoder.decode(CatalogGetResult.self, from: Data(json.utf8))
                return Model(handle: flm_model(parsed.modelHandle))
            },
            submit: { [handle] userData, _, onComplete, outJob in
                alias.withCString { aliasPtr in
                    flm_catalog_get_model_async(handle, aliasPtr, onComplete, userData, outJob)
                }
            }
        )
    }

    /// Resolve a model by its unique id, bypassing automatic variant selection. Useful
    /// when the app is pinning a specific variant across sessions.
    public func model(id: String) async throws -> Model {
        try await runAsyncJob(
            decode: { job in
                let json = try takeJobResultJSON(job)
                let parsed = try flmJSONDecoder.decode(CatalogGetResult.self, from: Data(json.utf8))
                return Model(handle: flm_model(parsed.modelHandle))
            },
            submit: { [handle] userData, _, onComplete, outJob in
                id.withCString { idPtr in
                    flm_catalog_get_model_by_id_async(handle, idPtr, onComplete, userData, outJob)
                }
            }
        )
    }

    /// Models already present in the local cache. Serves from disk, so it is
    /// synchronous and safe to call before any network is available.
    public func cachedModels() throws -> [ModelInfo] {
        let json = try readJSON { flm_catalog_list_cached_models_json(handle, $0) }
        return try flmJSONDecoder.decode([ModelInfo].self, from: Data(json.utf8))
    }

    /// Bytes currently used by the model cache.
    public var cacheSizeBytes: Int64 {
        var bytes: Int64 = 0
        return flm_catalog_get_cache_size_bytes(handle, &bytes) == FLM_OK ? bytes : 0
    }
}

/// Filter for ``Catalog/listModels``.
public struct CatalogFilter: Sendable {
    public var task: String?
    public var cachedOnly: Bool = false
    public var loadedOnly: Bool = false
    public var maxSizeBytes: Int64?
    public var compatibleOnly: Bool = false

    public init(
        task: String? = nil,
        cachedOnly: Bool = false,
        loadedOnly: Bool = false,
        maxSizeBytes: Int64? = nil,
        compatibleOnly: Bool = false
    ) {
        self.task = task
        self.cachedOnly = cachedOnly
        self.loadedOnly = loadedOnly
        self.maxSizeBytes = maxSizeBytes
        self.compatibleOnly = compatibleOnly
    }

    func encodeAsJSON() -> String {
        var payload: [String: Any] = [:]
        if let task { payload["task"] = task }
        if cachedOnly { payload["cached_only"] = true }
        if loadedOnly { payload["loaded_only"] = true }
        if let maxSizeBytes { payload["max_size_bytes"] = maxSizeBytes }
        if compatibleOnly { payload["compatible_only"] = true }
        return payload.jsonString() ?? "{}"
    }
}
