// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// URLSession-backed transport for foundry-local-mobile downloads.
//
// Why a background URLSession
// ===========================
//
// A model download is hundreds of megabytes to several gigabytes. iOS suspends foreground
// networking within seconds of the app going into the background; a plain `.default`
// `URLSessionConfiguration` would abort the transfer as soon as the user switches apps or
// locks the screen. A **background** configuration hands the transfer to the system
// `nsurlsessiond` daemon, which keeps it moving even after the process is suspended and
// — for the case where the app is killed — relaunches the app just to deliver the
// finished download. That is the entire point of this class existing.
//
// Background sessions have quirks worth being explicit about:
//
//   * Only download and upload tasks are supported. Data tasks (`URLSession.dataTask`)
//     silently fail. We therefore use `downloadTask` for every request, including
//     small in-memory ones — we just read the resulting temp file into memory and
//     forward the bytes to `TransportReport.body`.
//
//   * Only one URLSession per identifier can exist in the process at a time. The
//     first `init(identifier:)` claims the identifier; subsequent inits with the same
//     identifier would trap. `URLSessionBackgroundTransport.shared(identifier:)` is a
//     process-wide cache that returns the same instance to callers.
//
//   * The delegate is invoked on the session's delegate queue, not the caller's. That
//     is fine for the ABI, which is thread-safe, but it means everything we touch in
//     the delegate methods has to be thread-safe too.
//
//   * `didFinishDownloadingTo` hands us a temporary file URL that the system deletes
//     as soon as the delegate method returns. We MUST move (or read) the file
//     synchronously.
//
//   * After the app is killed, the system may relaunch it in the background to hand
//     off completed downloads through
//     `application(_:handleEventsForBackgroundURLSessionWithIdentifier:completionHandler:)`.
//     Apps must forward that call to
//     `URLSessionBackgroundTransport.registerBackgroundCompletionHandler(_:for:)`,
//     which we call when the delegate reports `urlSessionDidFinishEvents`.
//
// Range/resume semantics
// ======================
//
// The ABI's `flm_http_request.offset` is a resume hint. When it is greater than zero we:
//   * Add a `Range: bytes=<offset>-` header to the URLRequest.
//   * On success, APPEND the downloaded bytes to the existing destination file rather
//     than overwriting it. This is the only way the core's incremental download logic
//     works: it tracks the on-disk length and resumes from wherever it left off.
//
// URLSession supports its own opaque resume-data blob for suspended downloads, which
// preserves TLS handshakes and byte offsets across relaunches. We don't use that here
// because the core drives resume itself and only the byte offset survives across app
// deletes and reinstalls — resume data does not.

import Foundation
import FoundryLocalMobile

#if canImport(UIKit)
import UIKit
#endif

/// Default HTTP transport. Uses a background `URLSession` so a multi-gigabyte model
/// download survives the app being backgrounded.
///
/// Install it once, before any remote model source is added:
///
/// ```swift
/// let transport = URLSessionBackgroundTransport(identifier: "com.example.foundry.downloads")
/// TransportRegistry.install(transport)
/// ```
///
/// See ``registerBackgroundCompletionHandler(_:for:)`` for the app-delegate wiring the
/// OS requires to hand background events back to your process.
public final class URLSessionBackgroundTransport: NSObject, HTTPTransport, @unchecked Sendable {

    // MARK: - Public shared cache

    /// Return the shared transport for `identifier`, creating it on first use. Because
    /// iOS only allows one `URLSession` per background identifier per process, callers
    /// must never construct two `URLSessionBackgroundTransport` instances with the
    /// same identifier.
    public static func shared(identifier: String) -> URLSessionBackgroundTransport {
        Self.sharedCacheLock.lock()
        defer { Self.sharedCacheLock.unlock() }
        if let existing = sharedCache[identifier] {
            return existing
        }
        let instance = URLSessionBackgroundTransport(identifier: identifier)
        sharedCache[identifier] = instance
        return instance
    }

    nonisolated(unsafe) private static var sharedCache: [String: URLSessionBackgroundTransport] = [:]
    private static let sharedCacheLock = NSLock()

    // MARK: - Public API

    /// Session identifier passed to `URLSessionConfiguration.background(withIdentifier:)`.
    public let identifier: String
    private let allowsCellularAccess: Bool
    private let isDiscretionary: Bool

    public init(identifier: String, allowsCellularAccess: Bool = true, isDiscretionary: Bool = false) {
        self.identifier = identifier
        self.allowsCellularAccess = allowsCellularAccess
        self.isDiscretionary = isDiscretionary
        super.init()
        self.session = buildSession()
    }

    private func buildSession() -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.allowsCellularAccess = allowsCellularAccess
        config.isDiscretionary = isDiscretionary
        #if canImport(UIKit)
        // Only iOS-family platforms use this; on macOS it is unavailable and the
        // "app relaunched to deliver background events" story doesn't apply.
        config.sessionSendsLaunchEvents = true
        #endif
        return URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }

    // MARK: - Registered pending state

    /// The delegate serialisation queue. One thread means we don't need any lock for
    /// the `pending` map inside delegate methods; only the cross-thread `send`/`cancel`
    /// paths acquire ``stateLock``.
    private let delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "FoundryLocal.URLSessionBackgroundTransport"
        q.maxConcurrentOperationCount = 1
        return q
    }()

    /// Track pending download tasks keyed by ABI request id.
    struct PendingEntry {
        let request: HTTPRequest
        let task: URLSessionDownloadTask
    }

    private let stateLock = NSLock()
    private var pending: [UInt64: PendingEntry] = [:]

    /// The URLSession is built after `super.init()` because `URLSession(configuration:
    /// delegate:delegateQueue:)` needs `self`. Once assigned by the initializer, this
    /// is never nil for the lifetime of the transport.
    private var session: URLSession!

    // MARK: - Background completion handoff

    /// Application delegates should forward
    /// `application(_:handleEventsForBackgroundURLSessionWithIdentifier:completionHandler:)`
    /// here. iOS invokes it after relaunching an app in the background to deliver
    /// completed download events; we store the handler and invoke it when
    /// `urlSessionDidFinishEvents` fires, so the OS knows we've drained the queue.
    public static func registerBackgroundCompletionHandler(
        _ handler: @escaping @Sendable () -> Void,
        for identifier: String
    ) {
        backgroundHandlersLock.lock()
        backgroundCompletionHandlers[identifier] = handler
        backgroundHandlersLock.unlock()

        // Ensure the transport instance exists to receive the delegate events.
        _ = shared(identifier: identifier)
    }

    nonisolated(unsafe) private static var backgroundCompletionHandlers: [String: @Sendable () -> Void] = [:]
    private static let backgroundHandlersLock = NSLock()

    // MARK: - HTTPTransport

    public func send(_ request: HTTPRequest) -> Bool {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        if request.offset > 0 {
            urlRequest.setValue("bytes=\(request.offset)-", forHTTPHeaderField: "Range")
        }

        let task = session.downloadTask(with: urlRequest)
        // taskDescription survives serialisation of the URLSession across app launches
        // and is our stable identifier when the delegate is reattached.
        task.taskDescription = String(request.id)

        stateLock.lock()
        pending[request.id] = PendingEntry(request: request, task: task)
        stateLock.unlock()

        task.resume()
        return true
    }

    public func cancel(requestId: UInt64) {
        stateLock.lock()
        let entry = pending[requestId]
        stateLock.unlock()
        entry?.task.cancel()
    }

    // MARK: - Helpers

    private func pendingEntry(forTask task: URLSessionTask) -> PendingEntry? {
        guard let description = task.taskDescription, let id = UInt64(description) else {
            return nil
        }
        stateLock.lock()
        defer { stateLock.unlock() }
        return pending[id]
    }

    private func removePending(forId id: UInt64) {
        stateLock.lock()
        pending.removeValue(forKey: id)
        stateLock.unlock()
    }
}

// MARK: - URLSessionDownloadDelegate

extension URLSessionBackgroundTransport: URLSessionDownloadDelegate {

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let entry = pendingEntry(forTask: downloadTask) else { return }
        // Whether to fold `entry.request.offset` into the counters depends on what
        // the SERVER did, not what we asked for. A `Range` request that came back
        // as `206 Partial Content` means the body is the tail; add the prefix we
        // already have on disk so the caller sees a monotonic percentage across
        // resumes. A `Range` request that came back as `200 OK` means the server
        // ignored the range and is sending the whole resource — the counters
        // already cover the full download, and adding the offset on top would
        // report >100% and a bogus ETA.
        let serverHonouredRange = respondedWithPartialContent(downloadTask) && entry.request.offset > 0
        let offsetAdjustment: Int64 = serverHonouredRange ? entry.request.offset : 0
        let completed = totalBytesWritten + offsetAdjustment
        let total: Int64
        if totalBytesExpectedToWrite == NSURLSessionTransferSizeUnknown {
            total = Int64(FLM_UNKNOWN_SIZE)
        } else {
            total = totalBytesExpectedToWrite + offsetAdjustment
        }
        TransportReport.progress(id: entry.request.id, completedBytes: completed, totalBytes: total)
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let entry = pendingEntry(forTask: downloadTask) else { return }
        let request = entry.request

        // URLSession fires this delegate even for non-2xx responses — the "downloaded
        // file" is then the error body (a 404 page, a 500 stack trace). Writing that
        // into the destination would corrupt the model directory; the actual status
        // is surfaced by `didCompleteWithError` immediately after. Only 200 and 206
        // are legitimate write cases.
        let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard statusCode == 200 || statusCode == 206 else { return }
        let serverHonouredRange = statusCode == 206 && request.offset > 0

        // Synchronous work only — the temp file at `location` is deleted the moment
        // this method returns.
        if let destination = request.destinationPath {
            do {
                try saveDownload(from: location, to: destination, append: serverHonouredRange)
            } catch {
                TransportReport.complete(
                    id: request.id, statusCode: 0, headers: nil,
                    error: "failed to persist downloaded file: \(error)"
                )
                removePending(forId: request.id)
                return
            }
            // Completion status is delivered in `didCompleteWithError` below.
        } else {
            // In-memory delivery: read the file and forward to the ABI. Manifests
            // are small (a few tens of KB); reading them into RAM is fine.
            //
            // A read failure here MUST be surfaced — swallowing it would let
            // `didCompleteWithError` report a 200 with no body, and the core would
            // fail later with a confusing "unexpected empty document" from the
            // manifest parser instead of the real disk error.
            do {
                let data = try Data(contentsOf: location, options: [.mappedIfSafe])
                TransportReport.body(id: request.id, data: data)
            } catch {
                TransportReport.complete(
                    id: request.id, statusCode: 0, headers: nil,
                    error: "failed to read downloaded body: \(error)"
                )
                removePending(forId: request.id)
                return
            }
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let entry = pendingEntry(forTask: task) else { return }
        let request = entry.request
        let response = task.response as? HTTPURLResponse
        let statusCode: Int32
        if let response {
            statusCode = Int32(response.statusCode)
        } else if let nsError = error as NSError?,
                  nsError.domain == NSURLErrorDomain,
                  nsError.code == NSURLErrorCancelled {
            // Cancelled with no HTTP response — synthesise a client-cancel status so
            // the core recognises the exchange.
            statusCode = 499
        } else {
            statusCode = 0
        }

        let headers: [String: String]?
        if let response {
            var out: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                if let k = key as? String, let v = value as? String {
                    // Header names are case-insensitive; the core lower-cases on the
                    // way in, so we don't have to.
                    out[k] = v
                }
            }
            headers = out.isEmpty ? nil : out
        } else {
            headers = nil
        }

        let errorMessage = error.map { "\(($0 as NSError).localizedDescription)" }
        TransportReport.complete(
            id: request.id,
            statusCode: statusCode,
            headers: headers,
            error: errorMessage
        )
        removePending(forId: request.id)
    }

    /// Called when all background tasks associated with the session have finished
    /// delivering events. If the OS relaunched us to hand off downloads, this is where
    /// we call its completion handler to tell it we're done.
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        Self.backgroundHandlersLock.lock()
        let handler = Self.backgroundCompletionHandlers.removeValue(forKey: identifier)
        Self.backgroundHandlersLock.unlock()
        // The handler must be called on the main thread per Apple's docs.
        if let handler {
            DispatchQueue.main.async(execute: handler)
        }
    }
}

// MARK: - Persistence

private func saveDownload(from tempURL: URL, to destinationPath: String, append: Bool) throws {
    let fm = FileManager.default
    let destinationURL = URL(fileURLWithPath: destinationPath)
    try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    if append {
        // Server returned 206 Partial Content in response to our Range header, so
        // `tempURL` contains only the tail starting at the offset the core planned.
        // The prefix at `destinationPath` is what the core relied on when it asked
        // for a Range, so it must survive: open in append (`FileHandle.seekToEnd`
        // + write) rather than moving `tempURL` over the destination. Moving would
        // produce a same-length file whose leading `offset` bytes are the resumed
        // tail — passes any length check and only fails at the core's SHA-256
        // step, triggering a second full refetch of a corrupt outcome.
        guard fm.fileExists(atPath: destinationPath) else {
            // The core planned a resume against a file that is no longer on disk.
            // Fail loud so the core can re-plan from offset 0 rather than write
            // garbage.
            try? fm.removeItem(at: tempURL)
            throw NSError(
                domain: "FoundryLocal.URLSessionBackgroundTransport",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "resume requested but destination \(destinationPath) is missing",
                ]
            )
        }
        let src = try FileHandle(forReadingFrom: tempURL)
        let dst = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? src.close()
            try? dst.close()
        }
        try dst.seekToEnd()
        // Copy in reasonable chunks so a resumed multi-GB append doesn't spike RAM.
        while let chunk = try? src.read(upToCount: 1 << 16), let data = chunk, !data.isEmpty {
            try dst.write(contentsOf: data)
        }
        try? fm.removeItem(at: tempURL)
    } else {
        // Fresh download OR the server ignored our Range and sent a full 200 body.
        // Both mean `tempURL` is the whole resource from byte 0, so any stale
        // partial has to be discarded — moving the temp file over it is
        // self-healing for the "server ignored Range" case.
        if fm.fileExists(atPath: destinationPath) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.moveItem(at: tempURL, to: destinationURL)
    }

    // Mark the resulting file as ineligible for iCloud backup — model weights are
    // multi-gigabyte and should be re-downloadable rather than backed up.
    var url = destinationURL
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? url.setResourceValues(values)
}

private func respondedWithPartialContent(_ task: URLSessionTask) -> Bool {
    (task.response as? HTTPURLResponse)?.statusCode == 206
}
