// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import Foundation
import FoundryLocalMobile

/// Root object of the Swift SDK. Wraps a single `flm_manager` handle.
///
/// Owns:
///   * The manager handle (released on ``close()``).
///   * A ``LifecycleObserver`` forwarding OS notifications to the core.
///
/// Not typically instantiated more than once per process. iOS supports several
/// simultaneously, but they'll contend for the model cache directory unless each is
/// configured with a distinct ``FoundryLocalConfig/appDataDir``.
public final class FoundryLocal: @unchecked Sendable {
    public let handle: flm_manager

    private let released = ManagedAtomicBool()
    #if canImport(Darwin)
    private let lifecycle: LifecycleObserver
    #endif

    // MARK: - Construction

    /// The initializer is synchronous — the core does its own work on a job thread —
    /// but it *may* block briefly while the runtime is bound. Prefer calling it once
    /// at app launch off the main thread.
    public convenience init(config: FoundryLocalConfig) throws {
        let json = try config.encodeAsJSON()
        var handle: flm_manager = 0
        let status = json.withCString { flm_manager_create($0, &handle) }
        if status != FLM_OK {
            throw FoundryLocalError.fromCurrent(status: status)
        }
        try self.init(handle: handle)
    }

    public init(handle: flm_manager) throws {
        guard handle != 0 else {
            throw FoundryLocalError(code: .invalidHandle, message: "manager handle must not be zero")
        }
        self.handle = handle
        #if canImport(Darwin)
        self.lifecycle = LifecycleObserver(manager: handle)
        #endif
    }

    deinit {
        close()
    }

    // MARK: - Lifecycle

    /// Shut down and release the manager. Cancels in-flight jobs, unloads models and
    /// blocks briefly on outstanding work — safe to call from any thread but not from
    /// the main queue when a large model is loaded.
    public func close() {
        if released.exchange(true) { return }
        #if canImport(Darwin)
        lifecycle.stop()
        #endif
        _ = flm_manager_shutdown(handle)
        _ = flm_manager_release(handle)
    }

    // MARK: - Load model from path

    /// Load a model directly from a local directory path and return a ready-to-use
    /// ``Model``.
    ///
    /// This is the recommended entry point for on-device inference. It validates the
    /// directory, loads the model through the native runtime, and returns a ready
    /// ``Model`` handle in one call.
    ///
    /// ```swift
    /// let model = try await sdk.loadModel(
    ///     at: "/path/to/model/dir",
    ///     executionProvider: "CoreML"
    /// )
    /// let chat = try model.createChatSession()
    /// ```
    ///
    /// - Parameter path: Absolute filesystem path to the model directory. The
    ///   directory must already exist on disk.
    /// - Parameter executionProvider: Optional execution provider override, e.g.
    ///   `"CoreML"`.
    /// - Parameter providerOptions: Optional key-value EP configuration, forwarded
    ///   as `provider_options` to the OGA session (e.g. `["use_fp16": "1"]`).
    /// - Parameter progress: Optional progress callback for the load phase.
    /// - Returns: A loaded ``Model`` ready for session creation.
    /// - Throws: ``FoundryLocalError`` if the path is invalid or loading fails.
    public func loadModel(
        at path: String,
        executionProvider: String? = nil,
        providerOptions: [String: String]? = nil,
        progress: ((Progress) -> Void)? = nil
    ) async throws -> Model {
        let progressHandler: (@Sendable (Progress) -> Void)? = progress.map { callback in
            let box = ProgressCallbackBox(callback)
            return { value in box.callback(value) }
        }
        let options = loadModelOptions(
            executionProvider: executionProvider,
            providerOptions: providerOptions
        )
        let payload: LoadModelPayload = try await runAsyncJob(
            progress: progressHandler,
            decode: { job in
                let text = try takeJobResultJSON(job)
                return try flmJSONDecoder.decode(LoadModelPayload.self, from: Data(text.utf8))
            },
            submit: { [handle] userData, onProgress, onComplete, outJob in
                path.withCString { pathPtr in
                    options.withCString { optionsPtr in
                        flm_manager_load_model_async(handle, pathPtr, optionsPtr, onProgress, onComplete, userData, outJob)
                    }
                }
            }
        )
        guard payload.modelHandle != 0 else {
            throw FoundryLocalError(
                code: .invalidHandle,
                message: "No model handle returned for path '\(path)'."
            )
        }
        return Model(handle: flm_model(payload.modelHandle))
    }

    // MARK: - Introspection

    /// Read the device profile the core uses for model placement.
    public func deviceProfile() throws -> DeviceProfile {
        let json = try readJSON { flm_manager_get_device_profile_json(handle, $0) }
        return try flmJSONDecoder.decode(DeviceProfile.self, from: Data(json.utf8))
    }

    /// Runtime settings that can be updated after creation. Fields left `nil` are
    /// preserved. Corresponds to the subset of ``FoundryLocalConfig`` accepted by
    /// `flm_manager_update_settings`.
    public func updateSettings(
        logLevel: FoundryLocalConfig.LogLevel? = nil,
        autoUnloadOnBackground: Bool? = nil
    ) throws {
        var payload: [String: Any] = [:]
        if let v = logLevel { payload["log_level"] = v.rawValue }
        if let v = autoUnloadOnBackground { payload["auto_unload_on_background"] = v }
        guard !payload.isEmpty else { return }
        let json = payload.jsonString() ?? "{}"
        let status = json.withCString { flm_manager_update_settings(handle, $0) }
        if status != FLM_OK {
            throw FoundryLocalError.fromCurrent(status: status)
        }
    }

    /// Manually push a lifecycle event, for cases where the standard notifications
    /// aren't sufficient (e.g. an app-internal thermal signal).
    public func notify(lifecycle event: LifecycleEvent) {
        _ = flm_manager_notify_lifecycle(handle, event.cValue)
    }

    // MARK: - Static ABI helpers

    /// Version of this Swift SDK, sourced from the core.
    public static var version: String {
        guard let ptr = flm_version_string() else { return "unknown" }
        return String(cString: ptr)
    }

    /// Version of the underlying ONNX Runtime GenAI runtime, or `nil` when the runtime
    /// is not linked in — usually a build error rather than a runtime concern.
    public static var runtimeVersion: String? {
        guard let ptr = flm_runtime_version_string() else { return nil }
        return String(cString: ptr)
    }

    /// Whether the runtime is present and loadable at all. Fails silently — never
    /// logs, never crashes — so it is safe to call before any config exists.
    public static var isRuntimeAvailable: Bool {
        flm_is_runtime_available() != 0
    }

    /// Set the minimum severity forwarded through ``FoundryLocal/logSink``.
    public static func setLogLevel(_ level: FoundryLocalConfig.LogLevel) throws {
        let cLevel: flm_log_level
        switch level {
        case .verbose: cLevel = FLM_LOG_VERBOSE
        case .debug: cLevel = FLM_LOG_DEBUG
        case .info: cLevel = FLM_LOG_INFO
        case .warning: cLevel = FLM_LOG_WARNING
        case .error: cLevel = FLM_LOG_ERROR
        case .fatal: cLevel = FLM_LOG_FATAL
        case .off: cLevel = FLM_LOG_OFF
        }
        let status = flm_set_log_level(cLevel)
        if status != FLM_OK {
            throw FoundryLocalError.fromCurrent(status: status)
        }
    }

    private func loadModelOptions(
        executionProvider: String?,
        providerOptions: [String: String]?
    ) -> String {
        var payload: [String: Any] = [:]
        if let executionProvider { payload["execution_provider"] = executionProvider }
        if let providerOptions, !providerOptions.isEmpty { payload["provider_options"] = providerOptions }
        return payload.jsonString() ?? "{}"
    }
}

private final class ProgressCallbackBox: @unchecked Sendable {
    let callback: (Progress) -> Void

    init(_ callback: @escaping (Progress) -> Void) {
        self.callback = callback
    }
}

// MARK: - Lifecycle event mirror

public enum LifecycleEvent: Sendable {
    case foreground
    case background
    case memoryWarning
    case memoryCritical
    case lowPower
    case thermalThrottling

    var cValue: flm_lifecycle_event {
        switch self {
        case .foreground: return FLM_LIFECYCLE_FOREGROUND
        case .background: return FLM_LIFECYCLE_BACKGROUND
        case .memoryWarning: return FLM_LIFECYCLE_MEMORY_WARNING
        case .memoryCritical: return FLM_LIFECYCLE_MEMORY_CRITICAL
        case .lowPower: return FLM_LIFECYCLE_LOW_POWER
        case .thermalThrottling: return FLM_LIFECYCLE_THERMAL_THROTTLING
        }
    }
}
