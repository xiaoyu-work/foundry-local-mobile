// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

// URL isn't marked `Sendable` in corelibs Foundation on Linux, so `@preconcurrency`
// silences the noise there. On Apple SDKs URL has been `Sendable` since Swift 5.7,
// so the attribute is a no-op — real Sendable issues still surface.
@preconcurrency import Foundation
import FoundryLocalMobile

/// Model source flavour, mirroring the JSON shapes documented on
/// `flm_manager_add_model_source_async`.
///
/// A ``bundled`` source names a directory the app already put on disk; the runtime
/// loads it in place so the storage is not doubled. A ``remote`` source names a URL
/// that resolves to either a model package manifest or a flat file index — the SDK
/// figures out which from the document itself.
public enum ModelSource: Sendable {
    /// Model shipped inside the app bundle, extracted to `path` (or already a real
    /// path when it comes from a folder reference on iOS).
    ///
    /// The default is to load in place: the cache entry links back to `path` rather
    /// than copying the weights, so the app keeps owning those files and must keep
    /// them where they are. Pass `copyIntoCache: true` when it cannot promise that —
    /// a staging directory, or anything under `NSCachesDirectory`, which iOS may
    /// purge under storage pressure. For a package only the selected variant is
    /// copied.
    ///
    /// `verifyChecksums` still applies here: bundled model manifests may carry
    /// per-file SHA-256 hashes and the runtime checks them at load if this stays
    /// `true`. `resume` is a no-op for bundled sources since nothing downloads,
    /// but the ABI accepts the key on either kind. `constraints` picks a variant
    /// when the bundled directory is a package manifest.
    case bundled(
        name: String,
        path: String,
        copyIntoCache: Bool = false,
        constraints: VariantConstraints = .init(),
        resume: Bool = true,
        verifyChecksums: Bool = true
    )

    /// Model hosted on app-controlled storage. `headers` are sent with every request
    /// through the installed transport.
    ///
    /// `constraints` is the declarative, cross-platform way to pick a variant
    /// **before** any weights transfer: the runtime evaluates them against the
    /// manifest and only fetches the winning variant. Prefer this over the
    /// imperative ``Model/selectBestVariant`` for the acquisition path.
    ///
    /// - Parameter resume: When a partial download is on disk, ask the transport
    ///   to send `Range: bytes=<offset>-` and continue rather than start over.
    ///   Setting to `false` forces every restart to redownload the whole file.
    /// - Parameter verifyChecksums: Verify each file's SHA-256 against the
    ///   manifest after download. Setting to `false` is only sensible when your
    ///   own server enforces integrity (e.g. code-signed archives).
    case remote(
        name: String,
        url: URL,
        headers: [String: String] = [:],
        constraints: VariantConstraints = .init(),
        resume: Bool = true,
        verifyChecksums: Bool = true
    )

    func encodeAsJSON() throws -> String {
        var payload: [String: Any] = [:]
        switch self {
        case .bundled(let name, let path, let copy, let constraints, let resume, let verifyChecksums):
            payload["kind"] = "bundled"
            payload["name"] = name
            payload["path"] = path
            if copy { payload["copy_into_cache"] = true }
            encodeConstraints(into: &payload, constraints: constraints)
            encodeDownloadOptions(into: &payload, resume: resume, verifyChecksums: verifyChecksums)
        case .remote(let name, let url, let headers, let constraints, let resume, let verifyChecksums):
            payload["kind"] = "remote"
            payload["name"] = name
            payload["url"] = url.absoluteString
            if !headers.isEmpty { payload["headers"] = headers }
            encodeConstraints(into: &payload, constraints: constraints)
            encodeDownloadOptions(into: &payload, resume: resume, verifyChecksums: verifyChecksums)
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// Both flags default to `true` in the ABI, so we only emit a key when the caller
// opts out. This keeps the JSON minimal for the common case while still surfacing
// the option to callers that need to disable resume or checksum verification.
private func encodeDownloadOptions(
    into payload: inout [String: Any],
    resume: Bool,
    verifyChecksums: Bool
) {
    if !resume { payload["resume"] = false }
    if !verifyChecksums { payload["verify_checksums"] = false }
}

// Only emit `constraints` when at least one field is set. The default empty block
// would round-trip as `{}` which the core accepts but doesn't need.
private func encodeConstraints(into payload: inout [String: Any], constraints: VariantConstraints) {
    let inner = constraints.encodePayload()
    guard !inner.isEmpty else { return }
    payload["constraints"] = inner
}

extension ModelSource {
    /// Resolve a bundled model directory shipped as an Xcode folder reference (blue
    /// folder). Folder references preserve the model's directory structure in the app
    /// bundle at a real filesystem path, which is what the runtime needs.
    ///
    /// Pass the folder name (without a file extension) exactly as it appears in the
    /// bundle root. For a model at `MyApp.app/models/phi-4-mini`, call:
    ///
    /// ```swift
    /// let source = try ModelSource.bundled(name: "phi-4-mini",
    ///                                       folder: "phi-4-mini",
    ///                                       in: .main,
    ///                                       subdirectory: "models")
    /// ```
    ///
    /// - Throws: ``FoundryLocalError`` with ``FoundryLocalError/Code/notFound`` when
    ///   the folder is not in the bundle. Almost always the fix is switching the
    ///   Xcode target's file reference from a group (yellow) to a folder reference
    ///   (blue), which is documented in the README.
    public static func bundled(
        name: String,
        folder: String,
        in bundle: Bundle = .main,
        subdirectory: String? = nil,
        constraints: VariantConstraints = .init(),
        verifyChecksums: Bool = true
    ) throws -> ModelSource {
        // Bundle.url(forResource:withExtension:) returns nil for a directory without
        // an extension unless we pass `""` explicitly.
        guard let url = bundle.url(forResource: folder, withExtension: "", subdirectory: subdirectory)
                ?? bundle.url(forResource: folder, withExtension: nil, subdirectory: subdirectory) else {
            throw FoundryLocalError(
                code: .notFound,
                message: """
                Bundled model '\(folder)' not found in bundle '\(bundle.bundleIdentifier ?? "unknown")'. \
                Confirm the model directory is a folder reference (blue folder) in Xcode, \
                not a group.
                """
            )
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            throw FoundryLocalError(
                code: .invalidArgument,
                message: "Bundled model path '\(url.path)' is not a directory (exists=\(exists))."
            )
        }
        return .bundled(name: name, path: url.path, constraints: constraints, verifyChecksums: verifyChecksums)
    }
}

