// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import Foundation
import FoundryLocalMobile

/// A model, model package or package variant. All three flavours share this handle
/// type; the ABI disambiguates through ``isPackage``.
///
/// Sessions are created against a loaded model, so the typical lifecycle is:
///
/// ```swift
/// let added = try await sdk.addModelSource(
///     .remote(name: "qwen2.5-0.5b", url: myURL)
/// ) { p in print("\(p.percent)%") }
///
/// // `added.model` is the freshly-minted handle in the common case, nil only
/// // when the local catalog scan missed the fresh files; in that case fall
/// // back to the catalog by name.
/// let model = try await added.model ?? sdk.catalog.model(alias: added.name)
/// try await model.load()
/// let chat = try model.createChatSession()
/// ```
///
/// See ``FoundryLocal/addModelSource(_:progress:)`` for how a model gets on the
/// device in the first place.
public final class Model: @unchecked Sendable {
    public let handle: flm_model
    private let released = ManagedAtomicBool()

    init(handle: flm_model) {
        self.handle = handle
    }

    deinit {
        close()
    }

    /// Release the underlying handle. Idempotent, safe to call from any thread.
    /// Sessions created from this model become invalid.
    public func close() {
        if released.exchange(true) { return }
        _ = flm_model_release(handle)
    }

    /// Fetch metadata for this model. Reads from the ABI's cached document so this is
    /// cheap and safe on the caller's thread.
    public func info() throws -> ModelInfo {
        let json = try readJSON { flm_model_get_info_json(handle, $0) }
        return try flmJSONDecoder.decode(ModelInfo.self, from: Data(json.utf8))
    }

    /// Whether all of the model's files are present on disk.
    public var isCached: Bool {
        var flag: Int32 = 0
        return flm_model_is_cached(handle, &flag) == FLM_OK && flag != 0
    }

    /// Whether the model is currently loaded into memory.
    public var isLoaded: Bool {
        var flag: Int32 = 0
        return flm_model_is_loaded(handle, &flag) == FLM_OK && flag != 0
    }

    /// Whether this handle refers to a model package (a manifest with multiple
    /// variants) rather than a single flat model.
    public var isPackage: Bool {
        var flag: Int32 = 0
        return flm_model_is_package(handle, &flag) == FLM_OK && flag != 0
    }

    /// Absolute on-disk path once cached, or `nil` when the model has not been
    /// downloaded yet.
    public var cachedPath: String? {
        var out: UnsafeMutablePointer<CChar>?
        guard flm_model_get_path(handle, &out) == FLM_OK, let ptr = out else { return nil }
        defer { flm_string_free(ptr) }
        let path = String(cString: ptr)
        return path.isEmpty ? nil : path
    }

    // MARK: - Load lifecycle

    /// Load the model into memory.
    ///
    /// The model's files must already be resident on the device — either shipped in
    /// the app bundle via ``ModelSource/bundled(name:folder:in:subdirectory:constraints:verifyChecksums:)``
    /// or fetched by ``FoundryLocal/addModelSource(_:progress:)`` from an
    /// app-controlled URL. `load` does **not** download files on demand: the
    /// Foundry Local desktop catalog isn't reachable from mobile, so
    /// `flm_model_download_async` returns `notImplemented` for anything not already
    /// on disk. Ship your model, or host it yourself, then add it as a model
    /// source.
    ///
    /// - Parameter executionProvider: Optional EP override, e.g. `"CoreMLExecutionProvider"`.
    /// - Parameter device: Optional device placement override.
    public func load(
        executionProvider: String? = nil,
        device: Device? = nil,
        progress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws {
        let options = loadOptions(executionProvider: executionProvider, device: device)
        _ = try await runAsyncJob(
            progress: progress,
            decode: { job in
                // Load's job result is `{ path, bytes }` (LoadResult). We drop it
                // since callers already know the model they loaded; the info is
                // available via `Model.cachedPath` if they want it.
                _ = try? takeJobResultJSON(job)
                return ()
            },
            submit: { [handle] userData, onProgress, onComplete, outJob in
                options.withCString { optsPtr in
                    flm_model_load_async(handle, optsPtr, onProgress, onComplete, userData, outJob)
                }
            }
        )
    }

    /// Unload the model from memory. Sessions bound to it are stopped first.
    public func unload() async throws {
        _ = try await runAsyncJob(
            decode: { _ in () },
            submit: { [handle] userData, _, onComplete, outJob in
                flm_model_unload_async(handle, onComplete, userData, outJob)
            }
        )
    }

    /// Remove the model's files from the local cache. Unloads first if loaded.
    public func delete() async throws {
        _ = try await runAsyncJob(
            decode: { _ in () },
            submit: { [handle] userData, _, onComplete, outJob in
                flm_model_delete_async(handle, onComplete, userData, outJob)
            }
        )
    }

    // MARK: - Sessions

    /// Create a chat completion session over this model. The model must already be
    /// loaded — call ``load`` first, or use ``ChatSession/create(model:options:)`` at
    /// the top of your call graph.
    public func createChatSession(_ options: ChatSessionOptions = .init()) throws -> ChatSession {
        try ChatSession(model: self, options: options)
    }

    /// Create a live speech-to-text session over this model.
    public func createAudioSession(_ options: AudioSessionOptions = .init()) throws -> AudioSession {
        try AudioSession(model: self, options: options)
    }

    /// Create an embedding session over this model.
    public func createEmbeddingSession() throws -> EmbeddingSession {
        try EmbeddingSession(model: self)
    }

    // MARK: - Internal helpers

    private func loadOptions(executionProvider: String?, device: Device?) -> String {
        var payload: [String: Any] = [:]
        if let executionProvider { payload["execution_provider"] = executionProvider }
        if let device { payload["device"] = device.rawValue }
        return payload.jsonString() ?? "{}"
    }
}

// MARK: - Small utilities

/// A trivial atomic bool for the "release exactly once" guard on handle wrappers. We
/// avoid `swift-atomics` to keep the module dependency-free; `NSLock` is fast enough
/// for a one-shot flag.
final class ManagedAtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    /// Sets the flag to true and returns the previous value.
    func exchange(_ new: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let old = value
        value = new
        return old
    }
}

extension Dictionary where Key == String, Value == Any {
    func jsonString() -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: self, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

/// Common helper: call an ABI function that writes a `char**` out-parameter, and
/// return the resulting Swift string.
func readJSON(_ action: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> flm_status) throws -> String {
    var out: UnsafeMutablePointer<CChar>?
    let status = action(&out)
    if status != FLM_OK {
        throw FoundryLocalError.fromCurrent(status: status)
    }
    guard let ptr = out else { return "{}" }
    defer { flm_string_free(ptr) }
    return String(cString: ptr)
}
