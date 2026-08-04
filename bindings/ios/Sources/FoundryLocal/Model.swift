// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import Foundation
import FoundryLocalCore

/// A model, model package or package variant. All three flavours share this handle
/// type; the ABI disambiguates through ``isPackage``.
///
/// Sessions are created against a loaded model, so the typical lifecycle is:
///
/// ```swift
/// let model = try await catalog.model(alias: "qwen2.5-0.5b")
/// for try await progress in model.download() { … }
/// try await model.load()
/// let chat = try model.createChatSession()
/// ```
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

    // MARK: - Download / load lifecycle

    /// Download the model, streaming progress. Wraps `flm_model_download_async`.
    ///
    /// For a package handle this fetches the currently selected variant and the shared
    /// assets it needs, not the entire package. Use ``ModelPackage/selectVariant``
    /// (or ``ModelPackage/selectBestVariant``) first to control what is downloaded.
    ///
    /// - Parameter allowMetered: Override the manager-level metered policy for this
    ///   call. `nil` uses the manager setting.
    public func download(allowMetered: Bool? = nil) -> AsyncThrowingStream<DownloadProgress, Error> {
        let options = downloadOptions(allowMetered: allowMetered)
        return AsyncThrowingStream { streamCont in
            let jobBox = JobBox()
            let context = ProgressStreamContext(continuation: streamCont, jobBox: jobBox)
            let userData = Unmanaged.passRetained(context).toOpaque()

            var jobHandle: flm_job = 0
            let status = options.withCString { optsPtr in
                flm_model_download_async(
                    handle,
                    optsPtr,
                    _flm_progress_stream_bridge,
                    _flm_progress_stream_completion_bridge,
                    userData,
                    &jobHandle
                )
            }
            if status != FLM_OK {
                _ = Unmanaged<ProgressStreamContext>.fromOpaque(userData).takeRetainedValue()
                streamCont.finish(throwing: FoundryLocalError.fromCurrent(status: status))
                return
            }
            jobBox.set(jobHandle)
            streamCont.onTermination = { _ in
                let handle = jobBox.peek()
                if handle != 0 {
                    _ = flm_job_cancel(handle)
                }
            }
        }
    }

    /// Load the model into memory. Downloads the files first if needed.
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
                // Load's job result is `{ path, bytes }`; we don't surface it here.
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

    private func downloadOptions(allowMetered: Bool?) -> String {
        var payload: [String: Any] = [:]
        if let allowMetered { payload["allow_metered"] = allowMetered }
        return payload.jsonString() ?? "{}"
    }

    private func loadOptions(executionProvider: String?, device: Device?) -> String {
        var payload: [String: Any] = [:]
        if let executionProvider { payload["execution_provider"] = executionProvider }
        if let device { payload["device"] = device.rawValue }
        return payload.jsonString() ?? "{}"
    }
}

// MARK: - Progress stream bridge

/// Progress-only streaming variant that has no distinct terminal `Element`. Used by
/// downloads, which just want to expose progress plus errors.
final class ProgressStreamContext: @unchecked Sendable, ProgressForwarding, CompletionCarrier {
    let continuation: AsyncThrowingStream<DownloadProgress, Error>.Continuation
    let jobBox: JobBox

    init(continuation: AsyncThrowingStream<DownloadProgress, Error>.Continuation, jobBox: JobBox) {
        self.continuation = continuation
        self.jobBox = jobBox
    }

    func forwardProgress(_ progress: DownloadProgress) {
        continuation.yield(progress)
    }

    func deliverCompletion(job: flm_job, status: flm_status, errorJSON: UnsafePointer<CChar>?) {
        if status == FLM_OK {
            continuation.finish()
        } else if status == FLM_ERROR_CANCELLED {
            continuation.finish()
        } else {
            continuation.finish(throwing: FoundryLocalError.fromCurrent(status: status, errorJSON: errorJSON))
        }
    }
}

private let _flm_progress_stream_bridge: flm_progress_callback = { _, progressPtr, userData in
    guard let userData, let progressPtr else { return 0 }
    let context = Unmanaged<AnyObject>.fromOpaque(userData).takeUnretainedValue()
    if let carrier = context as? any ProgressForwarding {
        carrier.forwardProgress(DownloadProgress(cValue: progressPtr.pointee))
    }
    return 0
}

private let _flm_progress_stream_completion_bridge: flm_completion_callback = { job, status, errorJSON, userData in
    guard let userData else { return }
    let context = Unmanaged<AnyObject>.fromOpaque(userData).takeRetainedValue()
    if let carrier = context as? any CompletionCarrier {
        carrier.deliverCompletion(job: job, status: status, errorJSON: errorJSON)
    }
    _ = flm_job_release(job)
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
