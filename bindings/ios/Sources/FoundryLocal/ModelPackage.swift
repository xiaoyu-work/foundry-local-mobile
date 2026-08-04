// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import Foundation
import FoundryLocalMobile

/// Model-package facet of ``Model``. On a non-package handle these calls throw
/// ``FoundryLocalError/Code/invalidState``.
///
/// These are **inspection tools** for a package that is already on the device — they
/// walk the manifest, re-select a variant after the fact, or estimate what an app
/// would transfer. Primary variant selection is declarative: attach a
/// ``VariantConstraints`` to the ``ModelSource`` before calling
/// ``FoundryLocal/addModelSource(_:progress:)`` and the runtime picks the winning
/// variant against the manifest before any weights transfer. Use these methods for
/// after-the-fact re-selection, multi-variant orchestration, or a UI that wants to
/// let the user see every option.
extension Model {
    /// Enumerate this package's variants, each scored against the local device.
    ///
    /// `downloadSizeBytes` on the returned variants already excludes shared assets
    /// that happen to be present on disk — so it reflects what the user would
    /// actually transfer, not the theoretical variant size.
    public func variants() throws -> PackageVariants {
        let json = try readJSON { flm_package_get_variants_json(handle, $0) }
        return try flmJSONDecoder.decode(PackageVariants.self, from: Data(json.utf8))
    }

    /// Pin the package to a specific variant. Subsequent load / session calls act
    /// on it. Use this to switch variants after acquisition (say the user picked a
    /// different device tier in Settings) — for the initial acquisition, pass
    /// ``VariantConstraints`` on the ``ModelSource`` instead.
    public func selectVariant(_ variantId: String) throws {
        let status = variantId.withCString { flm_package_select_variant(handle, $0) }
        if status != FLM_OK {
            throw FoundryLocalError.fromCurrent(status: status)
        }
    }

    /// Re-run the SDK's variant selection over the manifest and pin the winner.
    /// Returns the variant id that was chosen.
    ///
    /// The runtime already applies constraints once at ``FoundryLocal/addModelSource(_:progress:)``
    /// time. Call this when the device situation has changed (thermal, storage,
    /// user preference) and the app wants to reselect without redownloading.
    ///
    /// - Throws: ``FoundryLocalError/Code/incompatible`` when no variant satisfies
    ///   the constraints (e.g. an NPU-only constraint on a device with no NPU).
    @discardableResult
    public func selectBestVariant(_ constraints: VariantConstraints = .init()) throws -> String {
        let constraintsJSON = constraints.encodeAsJSON()
        var out: UnsafeMutablePointer<CChar>?
        let status = constraintsJSON.withCString { constraintsPtr in
            flm_package_select_best_variant(handle, constraintsPtr, &out)
        }
        if status != FLM_OK {
            throw FoundryLocalError.fromCurrent(status: status)
        }
        guard let ptr = out else {
            throw FoundryLocalError(code: .internalError, message: "select_best_variant returned no id")
        }
        defer { flm_string_free(ptr) }
        return String(cString: ptr)
    }

    /// Return a standalone handle for one variant, useful when an app wants to manage
    /// multiple variants side by side (e.g. downloading an NPU variant while a CPU
    /// variant serves requests).
    public func variant(_ variantId: String) throws -> Model {
        var out: flm_model = 0
        let status = variantId.withCString { flm_package_get_variant(handle, $0, &out) }
        if status != FLM_OK {
            throw FoundryLocalError.fromCurrent(status: status)
        }
        return Model(handle: out)
    }

    /// Estimate the transfer for a set of variants before committing to the download.
    /// Passing `nil` uses the currently selected variant.
    public func estimateDownload(variantIds: [String]? = nil) throws -> DownloadEstimate {
        let arg: String?
        if let variantIds {
            let data = try JSONSerialization.data(withJSONObject: variantIds, options: [.sortedKeys])
            arg = String(data: data, encoding: .utf8)
        } else {
            arg = nil
        }
        let json = try readJSON { out in
            if let arg {
                return arg.withCString { flm_package_estimate_download_json(handle, $0, out) }
            } else {
                return flm_package_estimate_download_json(handle, nil, out)
            }
        }
        return try flmJSONDecoder.decode(DownloadEstimate.self, from: Data(json.utf8))
    }
}

/// Declarative variant policy applied against a package's manifest **before** any
/// weights are transferred.
///
/// This is the cross-platform way to say "NPU if you can, cap at 800 MB, otherwise
/// fall back to CPU": you attach it to a ``ModelSource`` and the runtime picks the
/// best-scoring variant that satisfies the constraints, then downloads only that
/// one. It also feeds the imperative ``Model/selectBestVariant`` for after-the-fact
/// re-selection.
///
/// Only the four fields below round-trip through the ABI. Any extra field would
/// be silently dropped.
public struct VariantConstraints: Sendable {
    /// Skip variants whose transfer would exceed this many bytes. `nil` = no limit.
    public var maxDownloadBytes: Int64?

    /// Consider only variants for these devices. Empty = any device.
    public var allowedDevices: Set<Device>

    /// Break ties on smallest transfer instead of highest compatibility score.
    public var preferSmallest: Bool

    /// Consider only variants already resident on disk. Useful for an offline
    /// pass that wants to re-select without triggering any transfer.
    public var requireCached: Bool

    public init(
        maxDownloadBytes: Int64? = nil,
        allowedDevices: Set<Device> = [],
        preferSmallest: Bool = false,
        requireCached: Bool = false
    ) {
        self.maxDownloadBytes = maxDownloadBytes
        self.allowedDevices = allowedDevices
        self.preferSmallest = preferSmallest
        self.requireCached = requireCached
    }

    func encodeAsJSON() -> String {
        encodePayload().jsonString() ?? "{}"
    }

    func encodePayload() -> [String: Any] {
        var payload: [String: Any] = [:]
        if let maxDownloadBytes { payload["max_download_bytes"] = maxDownloadBytes }
        if !allowedDevices.isEmpty {
            payload["allowed_devices"] = allowedDevices.map(\.rawValue).sorted()
        }
        if preferSmallest { payload["prefer_smallest"] = true }
        if requireCached { payload["require_cached"] = true }
        return payload
    }
}
