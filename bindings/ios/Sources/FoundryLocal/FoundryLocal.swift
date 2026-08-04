// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import Foundation
import FoundryLocalMobile

/// Root object of the Swift SDK. Wraps a single `flm_manager` handle.
///
/// Owns:
///   * The manager handle (released on ``close()``).
///   * The default background HTTP transport (unless the app installed its own).
///   * A ``LifecycleObserver`` forwarding OS notifications to the core.
///
/// Not typically instantiated more than once per process. iOS supports several
/// simultaneously, but they'll contend for the model cache directory unless each is
/// configured with a distinct ``FoundryLocalConfig/appDataDir``.
public final class FoundryLocal: @unchecked Sendable {
    public let handle: flm_manager

    /// The catalog is borrowed from the manager; releasing it is a no-op and it stays
    /// valid until this ``FoundryLocal`` is closed.
    public let catalog: Catalog

    private let released = ManagedAtomicBool()
    private let lifecycle: LifecycleObserver
    private let ownedTransport: URLSessionBackgroundTransport?

    // MARK: - Construction

    /// Create a new instance from a config. Installs the default background transport
    /// unless one has already been installed via ``TransportRegistry/install(_:)``.
    ///
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
        // Only install the default background transport when the app hasn't already
        // registered its own. This lets apps opt into certificate pinning or a custom
        // download queue by calling `TransportRegistry.install(_:)` before this init.
        let transport: URLSessionBackgroundTransport?
        if TransportRegistry.isInstalled {
            transport = nil
        } else {
            transport = URLSessionBackgroundTransport.shared(
                identifier: Self.defaultTransportIdentifier(appName: config.appName)
            )
        }
        try self.init(handle: handle, transport: transport)
    }

    /// Advanced init: build against an already-installed transport (e.g. a custom one
    /// with certificate pinning). Does not touch the ``TransportRegistry`` so an
    /// earlier install(nil) call is not overridden.
    public init(handle: flm_manager, transport: URLSessionBackgroundTransport? = nil) throws {
        guard handle != 0 else {
            throw FoundryLocalError(code: .invalidHandle, message: "manager handle must not be zero")
        }
        var catalogHandle: flm_catalog = 0
        let status = flm_manager_get_catalog(handle, &catalogHandle)
        if status != FLM_OK {
            _ = flm_manager_release(handle)
            throw FoundryLocalError.fromCurrent(status: status)
        }
        self.handle = handle
        self.catalog = Catalog(handle: catalogHandle)
        self.lifecycle = LifecycleObserver(manager: handle)
        self.ownedTransport = transport
        if let transport {
            TransportRegistry.install(transport)
        }
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
        lifecycle.stop()
        _ = flm_manager_shutdown(handle)
        _ = flm_manager_release(handle)
        // Do not call TransportRegistry.install(nil) here: the app may keep using
        // downloads after this instance is gone if it holds its own transport. If we
        // installed the default one, retain semantics keep it alive until the next
        // install().
    }

    // MARK: - Model sources

    /// Register an app-supplied model with the manager and hand back the result.
    ///
    /// **This is the model acquisition call on iOS.** The desktop Foundry Local
    /// catalog isn't reachable from mobile, so ``Catalog`` only surfaces what a
    /// source has already committed to disk. A model source is either a
    /// directory already on disk (``ModelSource/bundled(name:folder:in:subdirectory:constraints:verifyChecksums:)``)
    /// or a URL the app hosts (``ModelSource/remote(name:url:headers:constraints:resume:verifyChecksums:)``).
    ///
    /// For a bundled source this is fast (the files are already on disk). For a
    /// remote source it kicks off a possibly-multi-gigabyte download; progress is
    /// delivered through the closure.
    ///
    /// Variant selection is expressed declaratively via ``VariantConstraints`` on
    /// the source itself — the runtime picks the best variant against the manifest
    /// before any weights transfer, so the phone never spends bytes on the wrong
    /// build.
    ///
    /// The core mints a ready-to-use model handle inside the same job when the
    /// scan of the freshly-installed files succeeds, which is the common case.
    /// Read ``AddModelSourceResult/model`` and use it directly. When that field
    /// is `nil` the transfer still succeeded — the files are at
    /// ``AddModelSourceResult/path`` — and you can recover with a normal catalog
    /// lookup by name if you want a handle.
    public func addModelSource(
        _ source: ModelSource,
        progress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws -> AddModelSourceResult {
        let json = try source.encodeAsJSON()
        let payload: AddModelSourcePayload = try await runAsyncJob(
            progress: progress,
            decode: { job in
                let text = try takeJobResultJSON(job)
                return try flmJSONDecoder.decode(AddModelSourcePayload.self, from: Data(text.utf8))
            },
            submit: { [handle] userData, onProgress, onComplete, outJob in
                json.withCString { jsonPtr in
                    flm_manager_add_model_source_async(handle, jsonPtr, onProgress, onComplete, userData, outJob)
                }
            }
        )
        let model: Model? = payload.modelHandle != 0
            ? Model(handle: flm_model(payload.modelHandle))
            : nil
        // ABI reports `""` for a non-package source. Normalise to `nil` so
        // callers can just `if let variantId`.
        let variantId = payload.variantId.flatMap { $0.isEmpty ? nil : $0 }
        return AddModelSourceResult(
            name: payload.name,
            path: payload.path,
            variantId: variantId,
            bytesDownloaded: payload.bytesDownloaded,
            bytesReused: payload.bytesReused,
            wasCached: payload.wasCached,
            model: model
        )
    }

    // MARK: - Introspection

    /// Read the device profile the core uses for variant scoring.
    public func deviceProfile() throws -> DeviceProfile {
        let json = try readJSON { flm_manager_get_device_profile_json(handle, $0) }
        return try flmJSONDecoder.decode(DeviceProfile.self, from: Data(json.utf8))
    }

    /// Runtime settings that can be updated after creation. Fields left `nil` are
    /// preserved. Corresponds to the subset of ``FoundryLocalConfig`` accepted by
    /// `flm_manager_update_settings`.
    public func updateSettings(
        downloadOnMeteredNetwork: Bool? = nil,
        maxConcurrentDownloads: Int? = nil,
        logLevel: FoundryLocalConfig.LogLevel? = nil,
        autoUnloadOnBackground: Bool? = nil,
        offline: Bool? = nil
    ) throws {
        var payload: [String: Any] = [:]
        if let v = downloadOnMeteredNetwork { payload["download_on_metered_network"] = v }
        if let v = maxConcurrentDownloads { payload["max_concurrent_downloads"] = v }
        if let v = logLevel { payload["log_level"] = v.rawValue }
        if let v = autoUnloadOnBackground { payload["auto_unload_on_background"] = v }
        if let v = offline { payload["offline"] = v }
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

    // MARK: - Transport install (convenience)

    /// Install a custom transport. Passing `nil` uninstalls the current transport and
    /// leaves the SDK unable to download until another is installed. To restore the
    /// default background URLSession transport, pass a new
    /// ``URLSessionBackgroundTransport`` instance.
    public func setTransport(_ transport: (any HTTPTransport)?) {
        TransportRegistry.install(transport)
    }

    // MARK: - Static ABI helpers

    /// Version of this Swift SDK, sourced from the core.
    public static var version: String {
        guard let ptr = flm_version_string() else { return "unknown" }
        return String(cString: ptr)
    }

    /// Version of the underlying Foundry Local runtime, or `nil` when the runtime is
    /// not linked in — usually a build error rather than a runtime concern.
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

    private static func defaultTransportIdentifier(appName: String) -> String {
        let bundle = Bundle.main.bundleIdentifier ?? "app"
        return "\(bundle).foundrylocal.\(appName).downloads"
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
    case networkMetered
    case networkUnmetered

    var cValue: flm_lifecycle_event {
        switch self {
        case .foreground: return FLM_LIFECYCLE_FOREGROUND
        case .background: return FLM_LIFECYCLE_BACKGROUND
        case .memoryWarning: return FLM_LIFECYCLE_MEMORY_WARNING
        case .memoryCritical: return FLM_LIFECYCLE_MEMORY_CRITICAL
        case .lowPower: return FLM_LIFECYCLE_LOW_POWER
        case .thermalThrottling: return FLM_LIFECYCLE_THERMAL_THROTTLING
        case .networkMetered: return FLM_LIFECYCLE_NETWORK_METERED
        case .networkUnmetered: return FLM_LIFECYCLE_NETWORK_UNMETERED
        }
    }
}
