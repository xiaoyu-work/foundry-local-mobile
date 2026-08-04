// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import Foundation
import FoundryLocalMobile

/// Error type surfaced by every `FoundryLocal` operation.
///
/// Wraps the `flm_status` code plus the JSON error detail the ABI produces, so callers
/// can discriminate by ``code`` and inspect ``detail`` when they need extra context
/// (retry hints, HTTP status codes, offending model id, and so on).
public struct FoundryLocalError: Error, CustomStringConvertible, Sendable {
    /// Stable ABI status code.
    public let code: Code

    /// Human-readable message from the ABI. Empty when there is nothing useful to say.
    public let message: String

    /// Machine-readable detail JSON produced by `flm_last_error_detail_json`. Never
    /// empty — the ABI populates a stub when there is no additional context.
    public let detail: [String: SafeJSONValue]

    /// Whether the failed operation is worth retrying without any change of inputs.
    /// Reads the `retryable` hint from the detail JSON, defaulting to `false`.
    public var isRetryable: Bool {
        detail["retryable"]?.boolValue ?? code.isTransient
    }

    public var description: String {
        "FoundryLocalError(\(code): \(message.isEmpty ? "no message" : message))"
    }

    public init(code: Code, message: String, detail: [String: SafeJSONValue] = [:]) {
        self.code = code
        self.message = message
        self.detail = detail
    }

    /// Build an error from the raw C status and (optionally) the JSON string handed to
    /// a completion callback. Falls back to `flm_last_error_*` when `errorJSON` is nil.
    static func fromCurrent(status: flm_status, errorJSON: UnsafePointer<CChar>? = nil) -> FoundryLocalError {
        let code = Code(cValue: status)
        let (message, detail): (String, [String: SafeJSONValue])
        if let errorJSON, let parsed = parseErrorDetail(cString: errorJSON) {
            (message, detail) = parsed
        } else {
            let cMessage = flm_last_error_message()
            let cDetail = flm_last_error_detail_json()
            let msg = cMessage.map { String(cString: $0) } ?? ""
            let detailStr = cDetail.map { String(cString: $0) } ?? "{}"
            let parsed = parseErrorDetail(string: detailStr)
            (message, detail) = (msg, parsed?.1 ?? [:])
        }
        return FoundryLocalError(code: code, message: message, detail: detail)
    }

    private static func parseErrorDetail(cString: UnsafePointer<CChar>) -> (String, [String: SafeJSONValue])? {
        parseErrorDetail(string: String(cString: cString))
    }

    private static func parseErrorDetail(string: String) -> (String, [String: SafeJSONValue])? {
        guard let data = string.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let message = obj["message"] as? String ?? ""
        var detail: [String: SafeJSONValue] = [:]
        for (key, value) in obj {
            detail[key] = SafeJSONValue(any: value)
        }
        return (message, detail)
    }
}

extension FoundryLocalError {
    /// Mirror of `flm_status`. Named cases give call-sites readable pattern matching
    /// instead of raw ABI integers.
    public enum Code: Sendable, Equatable {
        case ok
        case internalError
        case invalidArgument
        case invalidHandle
        case invalidState
        case notFound
        case notImplemented
        case cancelled
        case network
        case storage
        case outOfMemory
        case incompatible
        case timeout
        case unsupportedVersion
        case memoryPressure
        case shutdown

        /// Map the ABI's `flm_status` onto a readable case. Unknown values (added by a
        /// newer core than this SDK was compiled against) collapse to `.internalError`.
        init(cValue: flm_status) {
            switch cValue {
            case FLM_OK: self = .ok
            case FLM_ERROR_INTERNAL: self = .internalError
            case FLM_ERROR_INVALID_ARGUMENT: self = .invalidArgument
            case FLM_ERROR_INVALID_HANDLE: self = .invalidHandle
            case FLM_ERROR_INVALID_STATE: self = .invalidState
            case FLM_ERROR_NOT_FOUND: self = .notFound
            case FLM_ERROR_NOT_IMPLEMENTED: self = .notImplemented
            case FLM_ERROR_CANCELLED: self = .cancelled
            case FLM_ERROR_NETWORK: self = .network
            case FLM_ERROR_STORAGE: self = .storage
            case FLM_ERROR_OUT_OF_MEMORY: self = .outOfMemory
            case FLM_ERROR_INCOMPATIBLE: self = .incompatible
            case FLM_ERROR_TIMEOUT: self = .timeout
            case FLM_ERROR_UNSUPPORTED_VERSION: self = .unsupportedVersion
            case FLM_ERROR_MEMORY_PRESSURE: self = .memoryPressure
            case FLM_ERROR_SHUTDOWN: self = .shutdown
            default: self = .internalError
            }
        }

        /// Errors that are worth another automatic attempt in the absence of other
        /// signals. The `retryable` hint in the detail JSON, when present, wins.
        var isTransient: Bool {
            switch self {
            case .network, .timeout, .memoryPressure:
                return true
            default:
                return false
            }
        }
    }
}

/// A very small, `Sendable`, `Codable`-free JSON representation used for error detail
/// bags. Full `Codable` decoding lives in ``JSONTypes`` for shapes we care about; the
/// error surface just needs a way to expose whatever the ABI happened to attach.
public enum SafeJSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([SafeJSONValue])
    case object([String: SafeJSONValue])

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int64? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int64(value)
        default: return nil
        }
    }

    init(any value: Any) {
        if value is NSNull {
            self = .null
        } else if let b = value as? Bool {
            self = .bool(b)
        } else if let n = value as? NSNumber {
            // NSNumber's ObjC type identifies whether the value is int- or float-shaped;
            // JSONSerialization normalises everything through NSNumber so we can't tell
            // them apart otherwise.
            let type = String(cString: n.objCType)
            if type == "c" || type == "B" {
                self = .bool(n.boolValue)
            } else if type == "d" || type == "f" {
                self = .double(n.doubleValue)
            } else {
                self = .int(n.int64Value)
            }
        } else if let s = value as? String {
            self = .string(s)
        } else if let a = value as? [Any] {
            self = .array(a.map { SafeJSONValue(any: $0) })
        } else if let o = value as? [String: Any] {
            var dict: [String: SafeJSONValue] = [:]
            for (k, v) in o { dict[k] = SafeJSONValue(any: v) }
            self = .object(dict)
        } else {
            self = .null
        }
    }
}
