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

    /// Minimum severity forwarded through ``FoundryLocal/logSink``.
    public var logLevel: LogLevel = .warning

    /// Unload loaded models when the app is backgrounded.
    public var autoUnloadOnBackground: Bool = true

    /// Job-pool thread count. `0` = derive from CPU cores.
    public var jobPoolThreads: Int = 0

    public init(
        appName: String,
        appDataDir: String? = nil,
        logLevel: LogLevel = .warning,
        autoUnloadOnBackground: Bool = true,
        jobPoolThreads: Int = 0
    ) {
        self.appName = appName
        self.appDataDir = appDataDir
        self.logLevel = logLevel
        self.autoUnloadOnBackground = autoUnloadOnBackground
        self.jobPoolThreads = jobPoolThreads
    }
}

extension FoundryLocalConfig {
    public enum LogLevel: String, Sendable, Codable {
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
            "auto_unload_on_background": autoUnloadOnBackground,
        ]
        payload["app_data_dir"] = appDataDir ?? Self.defaultAppDataDir(appName: appName)
        if jobPoolThreads > 0 { payload["job_pool_threads"] = jobPoolThreads }
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
        var logLevel: FoundryLocalConfig.LogLevel?
        var autoUnloadOnBackground: Bool?

        enum CodingKeys: String, CodingKey {
            case logLevel = "log_level"
            case autoUnloadOnBackground = "auto_unload_on_background"
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
            base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        }
        let dir = base.appendingPathComponent("FoundryLocal/\(appName)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return dir.path
    }
}
