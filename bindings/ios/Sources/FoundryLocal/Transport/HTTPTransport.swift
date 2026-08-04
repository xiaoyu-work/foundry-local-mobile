// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import Foundation
import FoundryLocalCore

/// One HTTP request the transport must perform, mirroring `flm_http_request` after the
/// borrowed C pointers have been copied into Swift-owned storage.
public struct HTTPRequest: Sendable {
    /// Echo this back to every `HTTPTransport` call and every `TransportReport` you
    /// make. It is how the core correlates progress and completion to the download it
    /// planned.
    public let id: UInt64
    public let url: URL
    public let method: String
    public let headers: [String: String]
    /// Filesystem path to write the body to. When `nil` the transport must instead
    /// deliver the body in memory via ``TransportReport/body``.
    public let destinationPath: String?
    /// Resume offset in bytes. When > 0 the request MUST carry a
    /// `Range: bytes=<offset>-` header and MUST append to any existing destination
    /// file rather than truncating it.
    public let offset: Int64
    /// Content-Length the core already knows about, or `nil` when unknown.
    public let expectedBytes: Int64?
}

/// A pluggable HTTP transport for downloads. Install one with
/// ``FoundryLocal/setTransport(_:)`` before adding a remote model source.
///
/// The default implementation is ``URLSessionBackgroundTransport`` — install a custom
/// transport only when you need certificate pinning, an in-house download queue, or a
/// custom authentication flow that static headers cannot express.
public protocol HTTPTransport: AnyObject, Sendable {
    /// Begin a request. MUST return immediately; the actual transfer runs elsewhere.
    /// Returning `false` fails the request without a report — the ABI treats it as a
    /// transport-level rejection.
    ///
    /// Return `true` after you have started the underlying task. You then MUST call
    /// ``TransportReport/complete(id:statusCode:headers:error:)`` exactly once, and
    /// exactly once, even on cancellation or failure — the core is holding a job
    /// thread waiting for that call.
    func send(_ request: HTTPRequest) -> Bool

    /// Cancel an in-flight request. The transport must STILL report completion (with
    /// a non-2xx status and/or `error` filled in).
    func cancel(requestId: UInt64)
}

/// Report an HTTP exchange back to the core. These are the Swift-typed wrappers around
/// `flm_transport_report_progress`, `flm_transport_report_body` and
/// `flm_transport_report_complete`.
///
/// All three are safe to call from any thread.
public enum TransportReport {
    /// Report bytes transferred for an in-flight request.
    public static func progress(id: UInt64, completedBytes: Int64, totalBytes: Int64) {
        _ = flm_transport_report_progress(id, completedBytes, totalBytes)
    }

    /// Deliver body bytes for an in-memory request (one whose `destinationPath` was
    /// nil). For file requests, write the body to `destinationPath` directly — do NOT
    /// call this.
    public static func body(id: UInt64, data: Data) {
        data.withUnsafeBytes { rawBuffer in
            let bound = rawBuffer.bindMemory(to: CChar.self)
            guard let base = bound.baseAddress else { return }
            _ = flm_transport_report_body(id, base, data.count)
        }
    }

    /// Finish the request. `error` is nil on success; otherwise it is any string that
    /// helps a human read the log.
    public static func complete(
        id: UInt64,
        statusCode: Int32,
        headers: [String: String]?,
        error: String? = nil
    ) {
        let headersJSON: String? = {
            guard let headers, !headers.isEmpty else { return nil }
            let data = try? JSONSerialization.data(withJSONObject: headers, options: [.sortedKeys])
            return data.flatMap { String(data: $0, encoding: .utf8) }
        }()
        headersJSON.withOptionalCString { headersPtr in
            error.withOptionalCString { errorPtr in
                _ = flm_transport_report_complete(id, statusCode, headersPtr, errorPtr)
            }
        }
    }
}

/// Install a transport as the current downloader, or clear it by passing `nil`.
///
/// The Swift wrapper retains the transport instance for its own lifetime through a
/// registry, and passes a stable `void*` to the ABI. The ABI copies the `flm_transport`
/// struct on the way in.
public enum TransportRegistry {
    private static let lock = NSLock()

    /// Currently installed transport, retained by the registry.
    nonisolated(unsafe) private static var current: (any HTTPTransport)?

    /// Retained `Unmanaged` pointer we handed to the ABI. Kept so we can release it
    /// when a new transport is installed. Access is guarded by ``lock``.
    nonisolated(unsafe) private static var installedBox: UnsafeMutableRawPointer?

    /// Whether a Swift transport is currently installed. Lets ``FoundryLocal`` skip
    /// its default install when the app has already registered a custom transport.
    public static var isInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return current != nil
    }

    /// Install a transport as the current downloader. Retains the transport for its
    /// lifetime as the current installer; the previous transport (if any) is released
    /// after the ABI has switched over. Passing `nil` uninstalls the current transport.
    ///
    /// **Call this before starting any download.** The ABI copies the `flm_transport`
    /// struct but keeps the `user_data` pointer verbatim, and installing while
    /// downloads are in flight would race between the old transport's callbacks and
    /// the release of its retained reference. Apps that need to swap transports
    /// mid-run must first pause outstanding downloads.
    public static func install(_ transport: (any HTTPTransport)?) {
        lock.lock()
        defer { lock.unlock() }

        // Retain the new transport (or nil-out) BEFORE swapping in the ABI, so the
        // C-side `user_data` we hand in is always a live, retained reference.
        let previousBox = installedBox
        current = transport

        if let transport {
            let userData = Unmanaged.passRetained(transport as AnyObject).toOpaque()
            var cTransport = flm_transport(
                version: UInt32(FLM_API_VERSION),
                send: _flm_transport_send_bridge,
                cancel: _flm_transport_cancel_bridge,
                user_data: userData
            )
            withUnsafePointer(to: &cTransport) { ptr in
                _ = flm_set_transport(ptr)
            }
            installedBox = userData
        } else {
            _ = flm_set_transport(nil)
            installedBox = nil
        }

        // Only release the previous retained pointer AFTER the ABI has fully switched
        // over — any in-flight `send`/`cancel` C dispatch that was reading the old
        // pointer has, by now, either completed or been redirected to the new one.
        if let previousBox {
            Unmanaged<AnyObject>.fromOpaque(previousBox).release()
        }
    }
}

// MARK: - C bridge callbacks

private let _flm_transport_send_bridge: @convention(c) (
    UnsafePointer<flm_http_request>?, UnsafeMutableRawPointer?
) -> Int32 = { requestPtr, userData in
    guard let requestPtr, let userData else { return -1 }
    let transport = Unmanaged<AnyObject>.fromOpaque(userData).takeUnretainedValue()
    guard let http = transport as? any HTTPTransport else { return -1 }

    let cRequest = requestPtr.pointee
    let request = buildRequest(from: cRequest)
    return http.send(request) ? 0 : -1
}

private let _flm_transport_cancel_bridge: @convention(c) (
    UInt64, UnsafeMutableRawPointer?
) -> Void = { requestId, userData in
    guard let userData else { return }
    let transport = Unmanaged<AnyObject>.fromOpaque(userData).takeUnretainedValue()
    (transport as? any HTTPTransport)?.cancel(requestId: requestId)
}

/// Copy the borrowed C strings inside `flm_http_request` into Swift-owned storage so
/// the transport can safely hand them to a background task that outlives the callback.
private func buildRequest(from cRequest: flm_http_request) -> HTTPRequest {
    let urlString = cRequest.url.map { String(cString: $0) } ?? ""
    let url = URL(string: urlString) ?? URL(fileURLWithPath: "/dev/null")
    let method = cRequest.method.map { String(cString: $0) } ?? "GET"

    var headers: [String: String] = [:]
    if let headerPtr = cRequest.headers_json {
        let headerString = String(cString: headerPtr)
        if let data = headerString.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in parsed {
                if let str = value as? String {
                    headers[key] = str
                }
            }
        }
    }

    let destination = cRequest.destination_path.map { String(cString: $0) }

    return HTTPRequest(
        id: cRequest.request_id,
        url: url,
        method: method,
        headers: headers,
        destinationPath: destination,
        offset: cRequest.offset,
        expectedBytes: cRequest.expected_bytes == Int64(FLM_UNKNOWN_SIZE) ? nil : cRequest.expected_bytes
    )
}

// MARK: - Optional-string C interop

extension Optional where Wrapped == String {
    /// Invoke `body` with a nullable `char*` matching this optional. `nil` maps to
    /// NULL. Copies into a temporary buffer so the pointer is valid for the body's
    /// scope but no longer.
    func withOptionalCString<Result>(_ body: (UnsafePointer<CChar>?) -> Result) -> Result {
        switch self {
        case .none:
            return body(nil)
        case .some(let value):
            return value.withCString { body($0) }
        }
    }
}
