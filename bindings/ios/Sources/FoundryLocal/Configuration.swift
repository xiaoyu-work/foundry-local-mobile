// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import Foundation

/// Top-level configuration for a ``FoundryLocal`` instance. Mirrors the JSON schema
/// documented on `flm_manager_create` — anything not required falls back to the ABI's
/// default so an app that only sets ``appName`` still works.
///
/// Fields with an `underscore_case` name in the ABI are exposed here in `camelCase`;
/// the config is serialised to JSON with a snake_case encoder before being handed to
/// the core.
public struct FoundryLocalConfig: Sendable {
    /// Non-empty identifier for the app. Used as a log tag and in cache keys.
    public var appName: String

    /// Application-private directory the core is allowed to persist state under.
    /// Defaults to the app's Application Support directory when nil.
    public var appDataDir: String?

    /// Directory the model cache lives in. Defaults to `<appDataDir>/models`.
    public var modelCacheDir: String?

    /// Directory the core writes its own logs to. Defaults to `<appDataDir>/logs`.
    public var logsDir: String?

    /// Minimum severity forwarded through ``FoundryLocal/logSink``.
    public var logLevel: LogLevel = .warning

    /// Alternate catalog URLs. Empty means "use the Foundry catalog".
    public var catalogUrls: [String] = []

    /// Azure region hint for the catalog. Ignored when custom URLs are set.
    public var catalogRegion: String?

    /// Serve only from the local cache. Fails downloads and catalog lookups that need
    /// the network.
    public var offline: Bool = false

    /// Concurrent download slots. `0` uses the ABI default (2).
    public var maxConcurrentDownloads: Int = 0

    /// Allow downloads over a cellular / metered connection.
    public var downloadOnMeteredNetwork: Bool = false

    /// Unload loaded models when the app is backgrounded.
    public var autoUnloadOnBackground: Bool = true

    /// Job-pool thread count. `0` = derive from CPU cores.
    public var jobPoolThreads: Int = 0

    /// Additional runtime-specific options, forwarded verbatim.
    public var additionalOptions: [String: String] = [:]

    public init(
        appName: String,
        appDataDir: String? = nil,
        modelCacheDir: String? = nil,
        logsDir: String? = nil,
        logLevel: LogLevel = .warning,
        catalogUrls: [String] = [],
        catalogRegion: String? = nil,
        offline: Bool = false,
        maxConcurrentDownloads: Int = 0,
        downloadOnMeteredNetwork: Bool = false,
        autoUnloadOnBackground: Bool = true,
        jobPoolThreads: Int = 0,
        additionalOptions: [String: String] = [:]
    ) {
        self.appName = appName
        self.appDataDir = appDataDir
        self.modelCacheDir = modelCacheDir
        self.logsDir = logsDir
        self.logLevel = logLevel
        self.catalogUrls = catalogUrls
        self.catalogRegion = catalogRegion
        self.offline = offline
        self.maxConcurrentDownloads = maxConcurrentDownloads
        self.downloadOnMeteredNetwork = downloadOnMeteredNetwork
        self.autoUnloadOnBackground = autoUnloadOnBackground
        self.jobPoolThreads = jobPoolThreads
        self.additionalOptions = additionalOptions
    }
}

extension FoundryLocalConfig {
    public enum LogLevel: String, Sendable {
        case verbose, debug, info, warning, error, fatal, off
    }
}

extension FoundryLocalConfig {
    /// Build the JSON payload the ABI expects on `flm_manager_create`, filling in the
    /// mobile-mandatory `app_data_dir` from the Application Support directory when the
    /// caller left it nil.
    func encodeAsJSON() throws -> String {
        var payload: [String: Any] = [
            "app_name": appName,
            "log_level": logLevel.rawValue,
            "offline": offline,
            "download_on_metered_network": downloadOnMeteredNetwork,
            "auto_unload_on_background": autoUnloadOnBackground,
        ]
        payload["app_data_dir"] = appDataDir ?? Self.defaultAppDataDir(appName: appName)
        if let modelCacheDir { payload["model_cache_dir"] = modelCacheDir }
        if let logsDir { payload["logs_dir"] = logsDir }
        if !catalogUrls.isEmpty { payload["catalog_urls"] = catalogUrls }
        if let catalogRegion { payload["catalog_region"] = catalogRegion }
        if maxConcurrentDownloads > 0 { payload["max_concurrent_downloads"] = maxConcurrentDownloads }
        if jobPoolThreads > 0 { payload["job_pool_threads"] = jobPoolThreads }
        if !additionalOptions.isEmpty { payload["additional_options"] = additionalOptions }

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Mutable settings subset accepted by `flm_manager_update_settings`. Fields that
    /// cannot be changed after creation are omitted deliberately.
    ///
    /// Not currently used by the SDK because `FoundryLocal.updateSettings` builds the
    /// JSON directly, but declared here to document the wire schema alongside the
    /// full config it derives from.
    struct RuntimeSettings: Encodable {
        var downloadOnMeteredNetwork: Bool?
        var maxConcurrentDownloads: Int?
        var logLevel: FoundryLocalConfig.LogLevel?
        var autoUnloadOnBackground: Bool?
        var offline: Bool?

        enum CodingKeys: String, CodingKey {
            case downloadOnMeteredNetwork = "download_on_metered_network"
            case maxConcurrentDownloads = "max_concurrent_downloads"
            case logLevel = "log_level"
            case autoUnloadOnBackground = "auto_unload_on_background"
            case offline
        }
    }

    private static func defaultAppDataDir(appName: String) -> String {
        let fm = FileManager.default
        let base: URL
        do {
            base = try fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        }
        // Sub-directory keyed by app name lets two SDK instances (say, host app and an
        // extension sharing the container) cohabit without stepping on each other.
        let dir = base.appendingPathComponent("FoundryLocal/\(appName)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir
        // Model caches on iOS are often multi-gigabyte; make sure iCloud doesn't try
        // to back them up.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return dir.path
    }
}
