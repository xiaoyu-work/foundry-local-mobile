// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import Foundation
import FoundryLocalMobile
import os

/// Route the core's internal log messages into `os_log`, or into a custom sink.
///
/// The C log callback is `@convention(c)`, so it can't capture state directly. We
/// store a Swift closure keyed by a process-global lock and dispatch through a static
/// C shim.
public enum FoundryLocalLog {

    public typealias Sink = @Sendable (Level, String, String) -> Void

    public enum Level: Int, Sendable {
        case verbose = 0
        case debug = 1
        case info = 2
        case warning = 3
        case error = 4
        case fatal = 5

        fileprivate init(_ raw: flm_log_level) {
            switch raw {
            case FLM_LOG_VERBOSE: self = .verbose
            case FLM_LOG_DEBUG: self = .debug
            case FLM_LOG_INFO: self = .info
            case FLM_LOG_WARNING: self = .warning
            case FLM_LOG_ERROR: self = .error
            case FLM_LOG_FATAL: self = .fatal
            default: self = .info
            }
        }
    }

    nonisolated(unsafe) private static var sink: Sink? = defaultOSLogSink
    private static let lock = NSLock()

    /// Install a sink to receive log messages. Passing `nil` reverts to the default
    /// `os_log` sink. To silence the ABI entirely, call ``uninstall()`` instead.
    public static func install(_ sink: Sink?) {
        lock.lock()
        Self.sink = sink ?? defaultOSLogSink
        lock.unlock()
        _ = flm_set_log_callback(_flm_log_bridge, nil)
    }

    /// Uninstall the ABI log callback, restoring pre-install silence. The default sink
    /// is not automatically restored on the next `install(_:)` call.
    public static func uninstall() {
        _ = flm_set_log_callback(nil, nil)
    }

    // MARK: - Internal

    fileprivate static let defaultOSLogSink: Sink = { level, tag, message in
        let type: OSLogType
        switch level {
        case .verbose, .debug: type = .debug
        case .info: type = .info
        case .warning: type = .default
        case .error: type = .error
        case .fatal: type = .fault
        }
        os_log("%{public}s: %{public}s", log: OSLog(subsystem: tag, category: "FoundryLocal"), type: type, tag, message)
    }
}

private let _flm_log_bridge: flm_log_callback = { rawLevel, tagPtr, messagePtr, _ in
    let level = FoundryLocalLog.Level(rawLevel)
    let tag = tagPtr.map { String(cString: $0) } ?? ""
    let message = messagePtr.map { String(cString: $0) } ?? ""
    FoundryLocalLog.lockedSink()?(level, tag, message)
}

extension FoundryLocalLog {
    /// Thread-safe read of the current sink.
    fileprivate static func lockedSink() -> Sink? {
        lock.lock()
        defer { lock.unlock() }
        return sink
    }
}
