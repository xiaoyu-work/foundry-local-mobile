// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import Foundation
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
    /// `verifyChecksums` still applies here: bundled model manifests may carry
    /// per-file SHA-256 hashes and the runtime checks them at load if this stays
    /// `true`. `resume` is a no-op for bundled sources since nothing downloads,
    /// but the ABI accepts the key on either kind.
    case bundled(
        name: String,
        path: String,
        copyIntoCache: Bool = false,
        resume: Bool = true,
        verifyChecksums: Bool = true
    )

    /// Model hosted on app-controlled storage. `headers` are sent with every request
    /// through the installed transport.
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
        resume: Bool = true,
        verifyChecksums: Bool = true
    )

    func encodeAsJSON() throws -> String {
        var payload: [String: Any] = [:]
        switch self {
        case .bundled(let name, let path, let copy, let resume, let verifyChecksums):
            payload["kind"] = "bundled"
            payload["name"] = name
            payload["path"] = path
            if copy { payload["copy_into_cache"] = true }
            encodeDownloadOptions(into: &payload, resume: resume, verifyChecksums: verifyChecksums)
        case .remote(let name, let url, let headers, let resume, let verifyChecksums):
            payload["kind"] = "remote"
            payload["name"] = name
            payload["url"] = url.absoluteString
            if !headers.isEmpty { payload["headers"] = headers }
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
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard isDirectory.boolValue else {
            throw FoundryLocalError(
                code: .invalidArgument,
                message: "Bundled model path '\(url.path)' is a file, not a directory."
            )
        }
        return .bundled(name: name, path: url.path, verifyChecksums: verifyChecksums)
    }
}

