// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Bridges between the ABI's job-plus-callback model and Swift structured concurrency.
//
// Design notes
// ============
//
// The ABI's contract:
//   * `flm_*_async` returns immediately with an `flm_job` handle.
//   * The completion callback fires exactly once, on a core job-pool thread, even on
//     cancellation. `flm_job_take_result_json` / `flm_job_release` must be called by
//     someone before the handle leaks.
//
// The Swift contract:
//   * A `CheckedContinuation` must be resumed **exactly once**, and Swift traps on
//     double-resume. That is the pointy end of the whole file.
//
// The two lines we walk very carefully:
//
//   1. If the caller's Task is cancelled *before* the ABI reports completion, we ask
//      the core to cancel (which triggers a completion with FLM_ERROR_CANCELLED) but we
//      must not resume the continuation until that completion actually arrives — the
//      core owns the handle and the result JSON.
//
//   2. Between the moment we hand the retained `Unmanaged` pointer to the ABI and the
//      moment we take it back in the completion callback, either side dropping the
//      reference is a bug: over-release crashes, over-retain leaks. So the bookkeeping
//      is: `passRetained` -> ABI accepts (return OK) -> `takeRetainedValue` in the
//      callback. If the ABI *rejects* the call (returns non-OK), we take it back with
//      `takeRetainedValue` and resume the continuation with the error, all before the
//      call returns.

import Foundation
import FoundryLocalCore

/// Continuation guarded by a lock, so an early cancel path and the eventual completion
/// callback can race for who wakes the awaiter, and only the first winner actually
/// resumes it.
final class ContinuationBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: error)
    }
}

/// Records the job handle for a call that has been submitted, so the cancellation
/// handler can find it. `set` publishes the handle; `takeIfPresent` returns it and
/// zeroes the box so cancellation and release don't race.
final class JobBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: flm_job = 0
    private var released = false

    func set(_ job: flm_job) {
        lock.lock()
        handle = job
        lock.unlock()
    }

    /// Read the handle without transferring ownership, for cancellation.
    func peek() -> flm_job {
        lock.lock()
        defer { lock.unlock() }
        return released ? 0 : handle
    }

    /// Take the handle and mark it as released, so we call `flm_job_release` exactly once.
    @discardableResult
    func take() -> flm_job {
        lock.lock()
        defer { lock.unlock() }
        if released { return 0 }
        released = true
        let h = handle
        handle = 0
        return h
    }
}

/// Envelope carried through `user_data` for one-shot async operations. Holds the
/// continuation box, the job handle box and — for callers that pass one — a progress
/// handler.
///
/// This class is retained across the FFI boundary via `Unmanaged`. The retain is
/// balanced by exactly one `takeRetainedValue` in the completion callback (or by the
/// early-fail branch of the caller).
final class AsyncCallContext<Value: Sendable>: @unchecked Sendable {
    let continuation: ContinuationBox<Value>
    let jobBox: JobBox
    let progress: (@Sendable (DownloadProgress) -> Void)?
    let decode: @Sendable (flm_job) throws -> Value

    init(
        continuation: ContinuationBox<Value>,
        jobBox: JobBox,
        progress: (@Sendable (DownloadProgress) -> Void)?,
        decode: @escaping @Sendable (flm_job) throws -> Value
    ) {
        self.continuation = continuation
        self.jobBox = jobBox
        self.progress = progress
        self.decode = decode
    }
}

/// C-compatible progress callback. Reads the context via `takeUnretainedValue` (this
/// callback may fire many times, so it must not consume the retained reference), unpacks
/// the `flm_progress` struct into ``DownloadProgress`` and forwards.
private let _flm_swift_progress_bridge: flm_progress_callback = { _, progressPtr, userData in
    guard let userData, let progressPtr else { return 0 }
    let context = Unmanaged<AnyObject>.fromOpaque(userData).takeUnretainedValue()
    let progress = DownloadProgress(cValue: progressPtr.pointee)

    // The context is one of the AsyncCallContext<T> generics. We keep the progress
    // forward abstract via a small protocol conformance to avoid a generic dance.
    if let carrier = context as? ProgressForwarding {
        carrier.forwardProgress(progress)
    }
    return 0
}

/// Protocol implemented by any context that wants progress deltas dispatched to it.
/// Lets the C bridge stay non-generic without losing type safety.
protocol ProgressForwarding: AnyObject {
    func forwardProgress(_ progress: DownloadProgress)
}

extension AsyncCallContext: ProgressForwarding {
    func forwardProgress(_ progress: DownloadProgress) {
        self.progress?(progress)
    }
}

// MARK: - Job driver

/// Run a one-shot async ABI call and bridge its job to Swift's structured concurrency.
///
/// - Parameter submit: Called synchronously to hand the callbacks and `user_data` to
///   the ABI. Returns the C status of the `flm_*_async` call plus the job handle it
///   wrote to `out_job`. Must not throw.
/// - Parameter decode: Called from the completion callback on success, to build the
///   Swift result from `flm_job_take_result_json`.
///
/// Cancellation of the surrounding Task calls `flm_job_cancel`. The completion
/// callback still fires (with FLM_ERROR_CANCELLED) and does the actual work of
/// resuming the continuation and releasing the job.
func runAsyncJob<Value: Sendable>(
    progress: (@Sendable (DownloadProgress) -> Void)? = nil,
    decode: @escaping @Sendable (flm_job) throws -> Value,
    submit: @escaping @Sendable (
        _ userData: UnsafeMutableRawPointer,
        _ onProgress: flm_progress_callback?,
        _ onComplete: flm_completion_callback,
        _ outJob: UnsafeMutablePointer<flm_job>
    ) -> flm_status
) async throws -> Value {
    let jobBox = JobBox()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Value, Error>) in
            let context = AsyncCallContext<Value>(
                continuation: ContinuationBox(cont),
                jobBox: jobBox,
                progress: progress,
                decode: decode
            )
            let userData = Unmanaged.passRetained(context).toOpaque()

            var jobHandle: flm_job = 0
            let status = submit(
                userData,
                progress != nil ? _flm_swift_progress_bridge : nil,
                _flm_swift_completion_bridge_generic,
                &jobHandle
            )

            if status != FLM_OK {
                // The ABI never accepted the call, so we own the retained reference
                // and must give it back; nothing on the core side is going to.
                _ = Unmanaged<AsyncCallContext<Value>>.fromOpaque(userData).takeRetainedValue()
                context.continuation.resume(throwing: FoundryLocalError.fromCurrent(status: status))
                return
            }
            jobBox.set(jobHandle)
        }
    } onCancel: {
        // `flm_job_cancel` is safe to call from any thread and is a no-op after
        // completion. We don't take the handle here — the completion callback still
        // owns the release.
        let handle = jobBox.peek()
        if handle != 0 {
            _ = flm_job_cancel(handle)
        }
    }
}

/// C-compatible completion callback shared by every ``runAsyncJob`` caller. Uses the
/// context's `decode` closure to build the typed result before resuming, so it does not
/// need to know the concrete `Value` type.
private let _flm_swift_completion_bridge_generic: flm_completion_callback = { job, status, errorJSON, userData in
    guard let userData else { return }

    // We can only downcast to a concrete generic type here by falling back to the
    // erased `CompletionCarrier` protocol. Every AsyncCallContext conforms.
    let context = Unmanaged<AnyObject>.fromOpaque(userData).takeRetainedValue()
    guard let carrier = context as? CompletionCarrier else {
        _ = flm_job_release(job)
        return
    }
    carrier.deliverCompletion(job: job, status: status, errorJSON: errorJSON)
    _ = flm_job_release(job)
}

/// Type-erased entry point used from the shared C completion bridge, so it does not
/// have to know the generic parameter of the calling ``AsyncCallContext``.
protocol CompletionCarrier: AnyObject {
    func deliverCompletion(job: flm_job, status: flm_status, errorJSON: UnsafePointer<CChar>?)
}

extension AsyncCallContext: CompletionCarrier {
    func deliverCompletion(job: flm_job, status: flm_status, errorJSON: UnsafePointer<CChar>?) {
        if status == FLM_OK {
            do {
                let value = try decode(job)
                continuation.resume(returning: value)
            } catch {
                continuation.resume(throwing: error)
            }
        } else {
            continuation.resume(throwing: FoundryLocalError.fromCurrent(status: status, errorJSON: errorJSON))
        }
    }
}

// MARK: - Streaming driver

/// Envelope for a streaming operation. Holds the stream's continuation plus the box
/// used to route the `onTermination` cancel.
final class StreamCallContext<Element: Sendable>: @unchecked Sendable {
    let continuation: AsyncThrowingStream<Element, Error>.Continuation
    let jobBox: JobBox
    let decodeDelta: @Sendable (UnsafePointer<flm_delta>) -> Element?
    let decodeFinal: @Sendable (flm_job) throws -> [Element]

    init(
        continuation: AsyncThrowingStream<Element, Error>.Continuation,
        jobBox: JobBox,
        decodeDelta: @escaping @Sendable (UnsafePointer<flm_delta>) -> Element?,
        decodeFinal: @escaping @Sendable (flm_job) throws -> [Element]
    ) {
        self.continuation = continuation
        self.jobBox = jobBox
        self.decodeDelta = decodeDelta
        self.decodeFinal = decodeFinal
    }
}

protocol DeltaCarrier: AnyObject {
    func forwardDelta(_ delta: UnsafePointer<flm_delta>)
    func finishStream(status: flm_status, job: flm_job, errorJSON: UnsafePointer<CChar>?)
}

extension StreamCallContext: DeltaCarrier {
    func forwardDelta(_ delta: UnsafePointer<flm_delta>) {
        if let element = decodeDelta(delta) {
            continuation.yield(element)
        }
    }

    func finishStream(status: flm_status, job: flm_job, errorJSON: UnsafePointer<CChar>?) {
        if status == FLM_OK {
            // Non-streaming operations produce their real result in the completion
            // JSON. Streaming ones (chat, transcribe) usually have already yielded
            // everything meaningful. `decodeFinal` gets a chance to emit tail
            // elements (usage summaries, `finish_reason`) built from the final JSON.
            do {
                for element in try decodeFinal(job) {
                    continuation.yield(element)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        } else if status == FLM_ERROR_CANCELLED {
            continuation.finish()
        } else {
            continuation.finish(throwing: FoundryLocalError.fromCurrent(status: status, errorJSON: errorJSON))
        }
    }
}

/// C-compatible delta callback shared by every ``runStreamingJob`` caller.
private let _flm_swift_delta_bridge: flm_delta_callback = { _, deltaPtr, userData in
    guard let userData, let deltaPtr else { return 0 }
    let context = Unmanaged<AnyObject>.fromOpaque(userData).takeUnretainedValue()
    if let carrier = context as? DeltaCarrier {
        carrier.forwardDelta(deltaPtr)
    }
    return 0
}

/// Completion callback for streaming operations. Consumes the retained reference —
/// there is exactly one completion per job.
private let _flm_swift_stream_completion_bridge: flm_completion_callback = { job, status, errorJSON, userData in
    guard let userData else { return }
    let context = Unmanaged<AnyObject>.fromOpaque(userData).takeRetainedValue()
    if let carrier = context as? DeltaCarrier {
        carrier.finishStream(status: status, job: job, errorJSON: errorJSON)
    }
    _ = flm_job_release(job)
}

/// Drive an ABI streaming call and expose it as an `AsyncThrowingStream`.
///
/// - Parameter decodeDelta: Convert each `flm_delta` into an `Element`. Return `nil`
///   for events we want to drop silently.
/// - Parameter decodeFinal: On terminal success, produce trailing elements built from
///   the final job JSON (e.g. usage totals).
/// - Parameter submit: Hand callbacks and user_data to the ABI.
///
/// Cancellation is wired in both directions: the stream's `onTermination` cancels the
/// job, and the completion callback still calls `flm_job_release`.
func runStreamingJob<Element: Sendable>(
    decodeDelta: @escaping @Sendable (UnsafePointer<flm_delta>) -> Element?,
    decodeFinal: @escaping @Sendable (flm_job) throws -> [Element] = { _ in [] },
    submit: @escaping @Sendable (
        _ userData: UnsafeMutableRawPointer,
        _ onDelta: flm_delta_callback,
        _ onComplete: flm_completion_callback,
        _ outJob: UnsafeMutablePointer<flm_job>
    ) -> flm_status
) -> AsyncThrowingStream<Element, Error> {
    AsyncThrowingStream { continuation in
        let jobBox = JobBox()
        let context = StreamCallContext<Element>(
            continuation: continuation,
            jobBox: jobBox,
            decodeDelta: decodeDelta,
            decodeFinal: decodeFinal
        )
        let userData = Unmanaged.passRetained(context).toOpaque()

        var jobHandle: flm_job = 0
        let status = submit(
            userData,
            _flm_swift_delta_bridge,
            _flm_swift_stream_completion_bridge,
            &jobHandle
        )

        if status != FLM_OK {
            _ = Unmanaged<StreamCallContext<Element>>.fromOpaque(userData).takeRetainedValue()
            continuation.finish(throwing: FoundryLocalError.fromCurrent(status: status))
            return
        }
        jobBox.set(jobHandle)

        continuation.onTermination = { _ in
            let handle = jobBox.peek()
            if handle != 0 {
                _ = flm_job_cancel(handle)
            }
        }
    }
}

// MARK: - Small helpers

/// Read the result JSON of a completed job, or return an empty object when it has no
/// meaningful result. The caller owns the returned string.
func takeJobResultJSON(_ job: flm_job) throws -> String {
    var out: UnsafeMutablePointer<CChar>?
    let status = flm_job_take_result_json(job, &out)
    if status != FLM_OK {
        throw FoundryLocalError.fromCurrent(status: status)
    }
    guard let ptr = out else { return "{}" }
    defer { flm_string_free(ptr) }
    return String(cString: ptr)
}
