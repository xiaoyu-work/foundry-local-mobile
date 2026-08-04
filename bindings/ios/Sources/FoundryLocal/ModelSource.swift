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
    case bundled(name: String, path: String, copyIntoCache: Bool = false)

    /// Model hosted on app-controlled storage. `headers` are sent with every request
    /// through the installed transport.
    case remote(name: String, url: URL, headers: [String: String] = [:])

    func encodeAsJSON() throws -> String {
        var payload: [String: Any] = [:]
        switch self {
        case .bundled(let name, let path, let copy):
            payload["kind"] = "bundled"
            payload["name"] = name
            payload["path"] = path
            if copy { payload["copy_into_cache"] = true }
        case .remote(let name, let url, let headers):
            payload["kind"] = "remote"
            payload["name"] = name
            payload["url"] = url.absoluteString
            if !headers.isEmpty { payload["headers"] = headers }
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
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
        subdirectory: String? = nil
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
        return .bundled(name: name, path: url.path)
    }
}
