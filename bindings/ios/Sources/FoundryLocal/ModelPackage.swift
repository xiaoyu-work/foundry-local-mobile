// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import Foundation
import FoundryLocalCore

/// Model-package facet of ``Model``. On a non-package handle these calls throw
/// ``FoundryLocalError/Code/invalidState``.
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

    /// Pin the package to a specific variant. Subsequent download / load / session
    /// calls act on it.
    public func selectVariant(_ variantId: String) throws {
        let status = variantId.withCString { flm_package_select_variant(handle, $0) }
        if status != FLM_OK {
            throw FoundryLocalError.fromCurrent(status: status)
        }
    }

    /// Let the SDK choose the best variant for this device, applying optional
    /// constraints. Returns the variant id that was chosen (also selected as the
    /// package's active variant).
    ///
    /// - Throws: ``FoundryLocalError/Code/incompatible`` when no variant satisfies the
    ///   constraints (e.g. an NPU-only constraint on a device with no NPU).
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

/// Constraints for ``Model/selectBestVariant``. Mirrors the JSON schema documented on
/// `flm_package_select_best_variant`.
public struct VariantConstraints: Sendable {
    /// Skip variants whose download would exceed this many bytes. `nil` = no limit.
    public var maxDownloadBytes: Int64?

    /// Only consider variants for these devices. `nil` = any device.
    public var allowedDevices: Set<Device>?

    /// Break ties on smallest download instead of highest compatibility score.
    public var preferSmallest: Bool = false

    public init(
        maxDownloadBytes: Int64? = nil,
        allowedDevices: Set<Device>? = nil,
        preferSmallest: Bool = false
    ) {
        self.maxDownloadBytes = maxDownloadBytes
        self.allowedDevices = allowedDevices
        self.preferSmallest = preferSmallest
    }

    func encodeAsJSON() -> String {
        var payload: [String: Any] = [:]
        if let maxDownloadBytes { payload["max_download_bytes"] = maxDownloadBytes }
        if let allowedDevices { payload["allowed_devices"] = allowedDevices.map(\.rawValue).sorted() }
        if preferSmallest { payload["prefer_smallest"] = true }
        return payload.jsonString() ?? "{}"
    }
}
