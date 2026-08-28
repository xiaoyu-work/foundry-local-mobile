// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Swift half of the iOS TurboModule for @foundry-local/react-native.
//
// Sits between the RN Objective-C++ shim (RNFoundryLocal.mm, RCTEventEmitter
// subclass) and the Swift binding at `bindings/ios/Sources/FoundryLocal/`.
// Owns:
//
//   * Three handle registries (managers, models, sessions) mirroring the
//     Kotlin binding's `HandleRegistry` pattern: JS sees a stable `Int`
//     slot id, native holds the object with retain semantics.
//   * A subscription table mapping JS-supplied `subscriptionId`s to their
//     backing `Task`, so `cancelSubscription` from JS translates into
//     `task.cancel()` which propagates through the `AsyncThrowingStream`'s
//     `onTermination` into `flm_job_cancel`.
//   * A weak reference to the RCTEventEmitter host so this class can emit
//     `FoundryLocal:*` events on the JS thread.
//
// Behavioural parity with the Android module (`FoundryLocalModule.kt` /
// `EventPayloads.kt`) is deliberate — the TypeScript layer expects a single
// wire shape for every event and every JSON payload regardless of platform.
// If you change a payload shape here, update the Android side too.
//
// Notes on cancellation semantics matching Android:
//   * Normal stream end        → emit `FoundryLocal:end`.
//   * Cancelled via cancelSubscription → emit `FoundryLocal:error` with
//     status=7 ("cancelled"); the promise resolves rather than rejecting
//     because the JS async iterator observes cancellation through the ERROR
//     event, not the promise return value.
//   * Native error             → emit `FoundryLocal:error` with the ABI
//     status/message/detail.

import Foundation
import React
import FoundryLocalMobile

/// Delegate the Swift core uses to emit RN events. Implemented by the
/// Objective-C++ RCTEventEmitter subclass so it can hop to the JS thread.
@objc public protocol RNFoundryLocalEmitting: AnyObject {
    func emitEvent(_ name: String, body: NSDictionary)
}

/// Slot-id registry mirroring the Kotlin binding's `HandleRegistry`.
/// Ids start at 1 so the JS side can treat `0` as "invalid handle".
///
/// **Do not replace this indirection with a raw `flm_handle`.** A core handle
/// packs a kind tag in its high bits and always exceeds `2^56`; JavaScript's
/// `number` is exact only to `2^53`, so passing one across the RN bridge
/// silently rounds away the low bits of the slot index and resolves to the
/// wrong slot rather than raising. Anything crossing to JS as an `NSNumber`
/// (see the `@objc` methods on `RNFoundryLocalCore`) must be a small
/// sequential id minted here. See `core/include/foundry_local_mobile/flm_types.h`
/// and the "Handles" section of `NativeFoundryLocal.ts` for the underlying
/// invariant.
private final class HandleRegistry<T: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private var nextId: Int = 1
    private var slots: [Int: T] = [:]

    func register(_ value: T) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextId
        nextId += 1
        slots[id] = value
        return id
    }

    func get(_ id: Int) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return slots[id]
    }

    func require(_ id: Int, kind: String) throws -> T {
        if let value = get(id) { return value }
        throw FoundryLocalError(
            code: .invalidHandle,
            message: "\(kind) handle \(id) is not registered"
        )
    }

    /// Remove the slot and return the value, or nil if the slot was empty.
    @discardableResult
    func release(_ id: Int) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return slots.removeValue(forKey: id)
    }

    /// Take every registered value and clear the table. Used on teardown.
    func releaseAll() -> [T] {
        lock.lock()
        defer { lock.unlock() }
        let values = Array(slots.values)
        slots.removeAll()
        return values
    }
}

// MARK: - Local JSON coders

// The Swift binding's own encoders/decoders (`flmJSONEncoder`, `flmJSONDecoder`)
// are internal to that module, so we mirror them here for the payloads we
// have to (de)serialise ourselves — device profile, model info list wrapping,
// tool result arrays, and so on.
private let rnJSONDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
}()

private let rnJSONEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return encoder
}()

// MARK: - Core

/// Core implementation. All work happens here; the Objective-C++ shim is a
/// straight forwarder plus RCTEventEmitter plumbing.
@objc(RNFoundryLocalCore)
public final class RNFoundryLocalCore: NSObject, @unchecked Sendable {

    // The RCTEventEmitter subclass that owns this core. Weak because the module
    // outlives us on teardown and RN retains it through the bridge.
    @objc public weak var host: RNFoundryLocalEmitting?

    private let managers = HandleRegistry<FoundryLocal>()
    private let models = HandleRegistry<Model>()
    private let sessions = HandleRegistry<AnyObject>()  // ChatSession | AudioSession | EmbeddingSession

    /// Backing tasks for streaming and long-running promises, keyed by
    /// JS-supplied subscription id.
    private let subscriptionsLock = NSLock()
    private var subscriptions: [String: Task<Void, Never>] = [:]

    @objc public override init() {
        super.init()
    }

    /// Called when RN tears down the module (Reload, app exit). Drops
    /// subscriptions and every native handle in the reverse order they were
    /// created — sessions first (they reference models), then models, then
    /// managers.
    @objc public func invalidate() {
        subscriptionsLock.lock()
        let tasks = Array(subscriptions.values)
        subscriptions.removeAll()
        subscriptionsLock.unlock()
        for t in tasks { t.cancel() }

        for s in sessions.releaseAll() {
            (s as? ChatSession)?.close()
            (s as? AudioSession)?.close()
            (s as? EmbeddingSession)?.close()
        }
        for m in models.releaseAll() { m.close() }
        for mgr in managers.releaseAll() { mgr.close() }
    }

    // MARK: - Subscription bookkeeping

    private func storeSubscription(_ id: String, task: Task<Void, Never>) {
        subscriptionsLock.lock()
        subscriptions[id] = task
        subscriptionsLock.unlock()
    }

    private func removeSubscription(_ id: String) {
        subscriptionsLock.lock()
        subscriptions.removeValue(forKey: id)
        subscriptionsLock.unlock()
    }

    private func takeSubscription(_ id: String) -> Task<Void, Never>? {
        subscriptionsLock.lock()
        defer { subscriptionsLock.unlock() }
        return subscriptions.removeValue(forKey: id)
    }

    /// Cancel and forget a subscription. Called when JS invokes
    /// `cancelSubscription(id)`.
    @objc public func cancelSubscription(_ subscriptionId: String) {
        if let task = takeSubscription(subscriptionId) {
            task.cancel()
        }
    }

    // MARK: - Event emission

    private func emit(_ name: String, body: [AnyHashable: Any]) {
        // The event emitter method is safe to call from any thread; it hops
        // to the JS queue internally.
        host?.emitEvent(name, body: body as NSDictionary)
    }

    private func emitError(_ subscriptionId: String, _ error: Error) {
        let (status, message, detail) = decodeError(error)
        var body: [AnyHashable: Any] = [
            "subscriptionId": subscriptionId,
            "status": status,
            "message": message,
        ]
        body["detail"] = detail as Any? ?? NSNull()
        emit("FoundryLocal:error", body: body)
    }

    private func emitEnd(_ subscriptionId: String, resultJson: String?) {
        var body: [AnyHashable: Any] = ["subscriptionId": subscriptionId]
        body["resultJson"] = resultJson as Any? ?? NSNull()
        emit("FoundryLocal:end", body: body)
    }

    private func emitProgress(_ subscriptionId: String, _ p: DownloadProgress) {
        // Match the Kotlin wire format: nullable numbers become 0, nullable
        // strings become explicit null.
        let progress: [AnyHashable: Any] = [
            "percent": Double(p.percent),
            "completedBytes": Double(p.completedBytes ?? 0),
            "totalBytes": Double(p.totalBytes ?? 0),
            "bytesPerSecond": Double(p.bytesPerSecond ?? 0),
            "etaMs": Double(p.etaMilliseconds ?? 0),
            "stage": p.stage.isEmpty ? NSNull() : p.stage,
            "detail": p.detail.isEmpty ? NSNull() : p.detail,
        ]
        emit("FoundryLocal:progress", body: [
            "subscriptionId": subscriptionId,
            "progress": progress,
        ])
    }

    private func emitDelta(_ subscriptionId: String, _ delta: [AnyHashable: Any]) {
        emit("FoundryLocal:delta", body: [
            "subscriptionId": subscriptionId,
            "delta": delta,
        ])
    }

    // MARK: - Manager

    @objc public func managerCreate(
        configJson: String,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        Task {
            do {
                let config = try self.decodeConfig(configJson)
                let sdk = try FoundryLocal(config: config)
                let id = self.managers.register(sdk)
                resolve(NSNumber(value: id))
            } catch {
                self.fail(reject, error)
            }
        }
    }

    @objc public func managerShutdown(
        managerId: NSNumber,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        Task {
            self.managers.get(managerId.intValue)?.close()
            resolve(NSNull())
        }
    }

    @objc public func managerRelease(managerId: NSNumber) {
        managers.release(managerId.intValue)?.close()
    }

    @objc public func managerUpdateSettings(managerId: NSNumber, configJson: String) throws {
        let manager = try managers.require(managerId.intValue, kind: "Manager")
        let update = try decodeSettings(configJson)
        try manager.updateSettings(
            logLevel: update.logLevel,
            autoUnloadOnBackground: update.autoUnloadOnBackground
        )
    }

    @objc public func managerGetDeviceProfile(managerId: NSNumber) throws -> String {
        let manager = try managers.require(managerId.intValue, kind: "Manager")
        let profile = try manager.deviceProfile()
        let data = try rnJSONEncoder.encode(profile)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // Version / runtime probes are static on the Swift binding (unlike Kotlin
    // where they hang off the instance). The RN spec still routes them
    // through a manager id for cross-platform symmetry — we look the manager
    // up to validate the id, then read the static.
    @objc public func managerVersion(managerId: NSNumber) throws -> String {
        _ = try managers.require(managerId.intValue, kind: "Manager")
        return FoundryLocal.version
    }

    @objc public func managerRuntimeVersion(managerId: NSNumber) throws -> String {
        _ = try managers.require(managerId.intValue, kind: "Manager")
        return FoundryLocal.runtimeVersion ?? ""
    }

    @objc public func managerIsRuntimeAvailable(managerId: NSNumber) throws -> NSNumber {
        _ = try managers.require(managerId.intValue, kind: "Manager")
        return NSNumber(value: FoundryLocal.isRuntimeAvailable)
    }

    @objc public func managerSetLogLevel(managerId: NSNumber, level: NSNumber) throws {
        _ = try managers.require(managerId.intValue, kind: "Manager")
        try FoundryLocal.setLogLevel(logLevelFromInt(level.intValue))
    }

    // MARK: - Load model

    @objc public func loadModel(
        managerId: NSNumber,
        modelPath: String,
        optionsJson: String?,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        let mgrId = managerId.intValue
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let manager = try self.managers.require(mgrId, kind: "Manager")
                let (ep, providerOptions, _) = try self.decodeLoadOptions(optionsJson)
                let model = try await manager.loadModel(
                    at: modelPath,
                    executionProvider: ep,
                    providerOptions: providerOptions,
                    progress: nil
                )
                let modelId = self.models.register(model)
                let info = try model.info()
                let data = try rnJSONEncoder.encode(info)
                var payload = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                payload["model_handle"] = modelId
                payload["path"] = model.cachedPath ?? modelPath
                payload["is_loaded"] = model.isLoaded
                resolve(self.jsonString(payload))
            } catch {
                self.fail(reject, error)
            }
        }
    }

    // MARK: - Model

    @objc public func modelGetInfo(modelId: NSNumber) throws -> String {
        let model = try models.require(modelId.intValue, kind: "Model")
        let info = try model.info()
        let data = try rnJSONEncoder.encode(info)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    @objc public func modelIsCached(modelId: NSNumber) throws -> NSNumber {
        let model = try models.require(modelId.intValue, kind: "Model")
        return NSNumber(value: model.isCached)
    }

    @objc public func modelIsLoaded(modelId: NSNumber) throws -> NSNumber {
        let model = try models.require(modelId.intValue, kind: "Model")
        return NSNumber(value: model.isLoaded)
    }

    @objc public func modelGetPath(modelId: NSNumber) throws -> String {
        let model = try models.require(modelId.intValue, kind: "Model")
        return model.cachedPath ?? ""
    }

    @objc public func modelLoad(
        modelId: NSNumber,
        optionsJson: String?,
        subscriptionId: String,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        let mId = modelId.intValue
        let task = Task { [weak self] in
            guard let self = self else { return }
            do {
                let model = try self.models.require(mId, kind: "Model")
                let (ep, providerOptions, device) = try self.decodeLoadOptions(optionsJson)
                try await model.load(executionProvider: ep, providerOptions: providerOptions, device: device) { progress in
                    self.emitProgress(subscriptionId, progress)
                }
                self.removeSubscription(subscriptionId)
                resolve(NSNull())
            } catch is CancellationError {
                self.removeSubscription(subscriptionId)
                self.fail(reject, FoundryLocalError(code: .cancelled, message: "cancelled"))
            } catch {
                self.removeSubscription(subscriptionId)
                self.fail(reject, error)
            }
        }
        storeSubscription(subscriptionId, task: task)
    }

    @objc public func modelUnload(
        modelId: NSNumber,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        let mId = modelId.intValue
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let model = try self.models.require(mId, kind: "Model")
                try await model.unload()
                resolve(NSNull())
            } catch { self.fail(reject, error) }
        }
    }

    @objc public func modelRelease(modelId: NSNumber) {
        models.release(modelId.intValue)?.close()
    }

    // MARK: - Sessions

    @objc public func sessionCreate(modelId: NSNumber, optionsJson: String) throws -> NSNumber {
        let model = try models.require(modelId.intValue, kind: "Model")
        let root = try parseObject(optionsJson)
        let type = (root["type"] as? String) ?? "chat"
        let session: AnyObject
        switch type {
        case "chat":
            session = try model.createChatSession(decodeChatOptions(root))
        case "audio":
            session = try model.createAudioSession(decodeAudioOptions(root))
        case "embedding":
            session = try model.createEmbeddingSession()
        default:
            throw FoundryLocalError(code: .invalidArgument, message: "Unknown session type '\(type)'")
        }
        return NSNumber(value: sessions.register(session))
    }

    @objc public func sessionRelease(sessionId: NSNumber) {
        guard let s = sessions.release(sessionId.intValue) else { return }
        (s as? ChatSession)?.close()
        (s as? AudioSession)?.close()
        (s as? EmbeddingSession)?.close()
    }

    @objc public func sessionSetOptions(sessionId: NSNumber, optionsJson: String) throws {
        let s = try sessions.require(sessionId.intValue, kind: "Session")
        guard let chat = s as? ChatSession else {
            throw FoundryLocalError(code: .invalidState, message: "setOptions is only supported on ChatSession")
        }
        let root = try parseObject(optionsJson)
        try chat.setOptions(decodeChatOptions(root))
    }

    @objc public func sessionExportHistory(sessionId: NSNumber) throws -> String {
        let s = try sessions.require(sessionId.intValue, kind: "Session")
        guard let chat = s as? ChatSession else {
            throw FoundryLocalError(code: .invalidState, message: "exportHistory is only supported on ChatSession")
        }
        return try chat.exportHistoryJSON()
    }

    @objc public func sessionRestoreHistory(sessionId: NSNumber, historyJson: String) throws {
        let s = try sessions.require(sessionId.intValue, kind: "Session")
        guard let chat = s as? ChatSession else {
            throw FoundryLocalError(code: .invalidState, message: "restoreHistory is only supported on ChatSession")
        }
        try chat.restoreHistory(fromJSON: historyJson)
    }

    @objc public func sessionClearHistory(sessionId: NSNumber) throws {
        let s = try sessions.require(sessionId.intValue, kind: "Session")
        guard let chat = s as? ChatSession else {
            throw FoundryLocalError(code: .invalidState, message: "clearHistory is only supported on ChatSession")
        }
        try chat.clearHistory()
    }

    @objc public func sessionUndoTurns(sessionId: NSNumber, count: NSNumber) throws {
        let s = try sessions.require(sessionId.intValue, kind: "Session")
        guard let chat = s as? ChatSession else {
            throw FoundryLocalError(code: .invalidState, message: "undoTurns is only supported on ChatSession")
        }
        try chat.undoTurns(count.intValue)
    }

    @objc public func sessionGetTurnCount(sessionId: NSNumber) throws -> NSNumber {
        let s = try sessions.require(sessionId.intValue, kind: "Session")
        guard let chat = s as? ChatSession else {
            throw FoundryLocalError(code: .invalidState, message: "getTurnCount is only supported on ChatSession")
        }
        return NSNumber(value: chat.turnCount)
    }

    @objc public func sessionComplete(
        sessionId: NSNumber,
        requestJson: String,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        let sId = sessionId.intValue
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let s = try self.sessions.require(sId, kind: "Session")
                guard let chat = s as? ChatSession else {
                    throw FoundryLocalError(code: .invalidState, message: "Session is not a chat session")
                }
                let request = try self.decodeChatRequest(requestJson)
                let completion = try await chat.complete(request)
                resolve(try self.encodeChatCompletion(completion))
            } catch {
                self.fail(reject, error)
            }
        }
    }

    @objc public func sessionCompleteStreaming(
        sessionId: NSNumber,
        requestJson: String,
        subscriptionId: String,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        let sId = sessionId.intValue
        do {
            let s = try sessions.require(sId, kind: "Session")
            guard let chat = s as? ChatSession else {
                throw FoundryLocalError(code: .invalidState, message: "Session is not a chat session")
            }
            let request = try decodeChatRequest(requestJson)
            let stream = chat.completeStreaming(request)
            let task = streamChatDeltas(subscriptionId: subscriptionId, stream: stream, resolve: resolve)
            storeSubscription(subscriptionId, task: task)
        } catch {
            fail(reject, error)
        }
    }

    @objc public func sessionSubmitToolResultsStreaming(
        sessionId: NSNumber,
        resultsJson: String,
        subscriptionId: String,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        let sId = sessionId.intValue
        do {
            let s = try sessions.require(sId, kind: "Session")
            guard let chat = s as? ChatSession else {
                throw FoundryLocalError(code: .invalidState, message: "Session is not a chat session")
            }
            let results = try decodeToolResults(resultsJson)
            let stream = chat.submitToolResults(results)
            let task = streamChatDeltas(subscriptionId: subscriptionId, stream: stream, resolve: resolve)
            storeSubscription(subscriptionId, task: task)
        } catch {
            fail(reject, error)
        }
    }

    @objc public func sessionTranscribe(
        sessionId: NSNumber,
        requestJson: String,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        let sId = sessionId.intValue
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let s = try self.sessions.require(sId, kind: "Session")
                guard let audio = s as? AudioSession else {
                    throw FoundryLocalError(code: .invalidState, message: "Session is not an audio session")
                }
                let req = try self.decodeTranscribeRequest(requestJson)
                let result: TranscriptionResult
                switch req {
                case .file(let path, let language, let translate):
                    result = try await audio.transcribe(path: path, language: language, translate: translate)
                case .inMemory, .streaming:
                    // The non-streaming `transcribe` overload only accepts a
                    // file path in the Swift binding; base64 / streaming
                    // requests fall through to the streaming API. Reject
                    // here for symmetry with Android's error path.
                    throw FoundryLocalError(
                        code: .invalidArgument,
                        message: "sessionTranscribe requires a file path; use sessionTranscribeStreaming for in-memory or live input."
                    )
                }
                resolve(try self.encodeTranscription(result))
            } catch {
                self.fail(reject, error)
            }
        }
    }

    @objc public func sessionTranscribeStreaming(
        sessionId: NSNumber,
        requestJson: String,
        subscriptionId: String,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        let sId = sessionId.intValue
        do {
            let s = try sessions.require(sId, kind: "Session")
            guard let audio = s as? AudioSession else {
                throw FoundryLocalError(code: .invalidState, message: "Session is not an audio session")
            }
            let req = try decodeTranscribeRequest(requestJson)
            let stream: AsyncThrowingStream<SpeechDelta, Error>
            switch req {
            case .file(let path, let language, let translate):
                stream = audio.transcribeStreaming(path: path, language: language, translate: translate)
            case .inMemory(let base64, let format, let sampleRate, let channels, let language, let translate):
                stream = audio.transcribeStreaming(
                    base64: base64,
                    format: format,
                    sampleRate: sampleRate,
                    channels: channels,
                    language: language,
                    translate: translate
                )
            case .streaming(let language, let translate):
                stream = audio.startStreamingTranscription(language: language, translate: translate)
            }
            let task = streamSpeechDeltas(subscriptionId: subscriptionId, stream: stream, resolve: resolve)
            storeSubscription(subscriptionId, task: task)
        } catch {
            fail(reject, error)
        }
    }

    @objc public func sessionPushAudio(
        sessionId: NSNumber,
        pcmBase64: String,
        sampleRate: NSNumber,
        channels: NSNumber,
        isFinal: NSNumber
    ) throws {
        let s = try sessions.require(sessionId.intValue, kind: "Session")
        guard let audio = s as? AudioSession else {
            throw FoundryLocalError(code: .invalidState, message: "Session is not an audio session")
        }
        guard let data = Data(base64Encoded: pcmBase64) else {
            throw FoundryLocalError(code: .invalidArgument, message: "Invalid base64 PCM buffer")
        }
        try audio.pushAudio(
            data,
            sampleRate: sampleRate.int32Value,
            channels: channels.int32Value,
            isFinal: isFinal.boolValue
        )
    }

    @objc public func sessionEmbed(
        sessionId: NSNumber,
        requestJson: String,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        let sId = sessionId.intValue
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let s = try self.sessions.require(sId, kind: "Session")
                guard let embed = s as? EmbeddingSession else {
                    throw FoundryLocalError(code: .invalidState, message: "Session is not an embedding session")
                }
                let inputs = try self.decodeEmbedInputs(requestJson)
                let result = try await embed.embed(inputs)
                resolve(try self.encodeEmbedding(result))
            } catch {
                self.fail(reject, error)
            }
        }
    }

    // MARK: - Streaming helpers

    private func streamChatDeltas(
        subscriptionId: String,
        stream: AsyncThrowingStream<ChatDelta, Error>,
        resolve: @escaping RCTPromiseResolveBlock
    ) -> Task<Void, Never> {
        return Task { [weak self] in
            guard let self = self else { return }
            var terminalEmitted = false
            do {
                for try await delta in stream {
                    self.emitDelta(subscriptionId, self.encodeChatDelta(delta))
                }
                if Task.isCancelled {
                    terminalEmitted = true
                    self.emit("FoundryLocal:error", body: [
                        "subscriptionId": subscriptionId,
                        "status": 7,
                        "message": "cancelled",
                        "detail": NSNull(),
                    ])
                } else {
                    terminalEmitted = true
                    self.emitEnd(subscriptionId, resultJson: nil)
                }
            } catch {
                terminalEmitted = true
                self.emitError(subscriptionId, error)
            }
            self.removeSubscription(subscriptionId)
            // Match Android: resolve regardless of how the stream ended; the
            // JS side observes terminal state through the emitted event.
            _ = terminalEmitted
            resolve(NSNull())
        }
    }

    private func streamSpeechDeltas(
        subscriptionId: String,
        stream: AsyncThrowingStream<SpeechDelta, Error>,
        resolve: @escaping RCTPromiseResolveBlock
    ) -> Task<Void, Never> {
        return Task { [weak self] in
            guard let self = self else { return }
            do {
                for try await delta in stream {
                    self.emitDelta(subscriptionId, self.encodeSpeechDelta(delta))
                }
                if Task.isCancelled {
                    self.emit("FoundryLocal:error", body: [
                        "subscriptionId": subscriptionId,
                        "status": 7,
                        "message": "cancelled",
                        "detail": NSNull(),
                    ])
                } else {
                    self.emitEnd(subscriptionId, resultJson: nil)
                }
            } catch {
                self.emitError(subscriptionId, error)
            }
            self.removeSubscription(subscriptionId)
            resolve(NSNull())
        }
    }

    // MARK: - Promise reject helper

    private func fail(_ reject: @escaping RCTPromiseRejectBlock, _ error: Error) {
        let (status, message, detail) = decodeError(error)
        var userInfo: [String: Any] = ["status": status]
        if let detail { userInfo["detail"] = detail }
        let nsError = NSError(domain: "FoundryLocal", code: status, userInfo: userInfo)
        reject(errorCode(status), message, nsError)
    }

    private func decodeError(_ error: Error) -> (Int, String, String?) {
        if let fle = error as? FoundryLocalError {
            let status = statusCodeForError(fle.code)
            let detail = encodeDetail(fle.detail)
            return (status, fle.message.isEmpty ? "\(fle.code)" : fle.message, detail)
        }
        if error is CancellationError {
            return (7, "cancelled", nil)
        }
        let ns = error as NSError
        return (1, ns.localizedDescription, nil)
    }

    private func encodeDetail(_ detail: [String: SafeJSONValue]) -> String? {
        guard !detail.isEmpty else { return nil }
        // SafeJSONValue is enum-typed; convert back to a JSONSerialization-
        // friendly nested representation so we can hand a JSON string over
        // the bridge.
        let native = detail.mapValues { safeToNative($0) }
        guard JSONSerialization.isValidJSONObject(native),
              let data = try? JSONSerialization.data(withJSONObject: native) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func safeToNative(_ v: SafeJSONValue) -> Any {
        switch v {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return NSNumber(value: i)
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { safeToNative($0) }
        case .object(let o):
            var dict = [String: Any]()
            for (k, v) in o { dict[k] = safeToNative(v) }
            return dict
        }
    }

    private func statusCodeForError(_ code: FoundryLocalError.Code) -> Int {
        switch code {
        case .ok: return 0
        case .internalError: return 1
        case .invalidArgument: return 2
        case .invalidHandle: return 3
        case .invalidState: return 4
        case .notFound: return 5
        case .notImplemented: return 6
        case .cancelled: return 7
        case .network: return 8
        case .storage: return 9
        case .outOfMemory: return 10
        case .incompatible: return 11
        case .timeout: return 12
        case .unsupportedVersion: return 13
        case .memoryPressure: return 14
        case .shutdown: return 15
        }
    }

    private func errorCode(_ status: Int) -> String {
        switch status {
        case 2: return "invalidArgument"
        case 3: return "invalidHandle"
        case 4: return "invalidState"
        case 5: return "notFound"
        case 6: return "notImplemented"
        case 7: return "cancelled"
        case 8: return "network"
        case 9: return "storage"
        case 10: return "outOfMemory"
        case 11: return "incompatible"
        case 12: return "timeout"
        case 13: return "unsupportedVersion"
        case 14: return "memoryPressure"
        case 15: return "shutdown"
        default: return "internal"
        }
    }
}

// MARK: - JSON encoders / decoders

extension RNFoundryLocalCore {

    private func parseObject(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FoundryLocalError(code: .invalidArgument, message: "Expected JSON object")
        }
        return obj
    }

    private func jsonString(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    fileprivate func decodeConfig(_ json: String) throws -> FoundryLocalConfig {
        let o = try parseObject(json)
        return FoundryLocalConfig(
            appName: (o["app_name"] as? String) ?? "app",
            appDataDir: o["app_data_dir"] as? String,
            logLevel: logLevelFromString(o["log_level"] as? String),
            autoUnloadOnBackground: (o["auto_unload_on_background"] as? Bool) ?? true,
            jobPoolThreads: (o["job_pool_threads"] as? Int) ?? 0
        )
    }

    fileprivate struct SettingsUpdate {
        let logLevel: FoundryLocalConfig.LogLevel?
        let autoUnloadOnBackground: Bool?
    }

    fileprivate func decodeSettings(_ json: String) throws -> SettingsUpdate {
        let o = try parseObject(json)
        return SettingsUpdate(
            logLevel: (o["log_level"] as? String).flatMap { FoundryLocalConfig.LogLevel(rawValue: $0) },
            autoUnloadOnBackground: o["auto_unload_on_background"] as? Bool
        )
    }

    fileprivate func logLevelFromString(_ s: String?) -> FoundryLocalConfig.LogLevel {
        guard let s, let level = FoundryLocalConfig.LogLevel(rawValue: s) else {
            return .warning
        }
        return level
    }

    fileprivate func logLevelFromInt(_ value: Int) -> FoundryLocalConfig.LogLevel {
        // Mirrors the C ABI's `flm_log_level` ordering.
        switch value {
        case 0: return .verbose
        case 1: return .debug
        case 2: return .info
        case 3: return .warning
        case 4: return .error
        case 5: return .fatal
        case 6: return .off
        default: return .warning
        }
    }

    fileprivate func decodeLoadOptions(_ json: String?) throws -> (String?, [String: String]?, Device?) {
        guard let json, !json.isEmpty else { return (nil, nil, nil) }
        let o = try parseObject(json)
        let ep = o["execution_provider"] as? String
        let providerOptions = o["provider_options"] as? [String: String]
        let device: Device? = (o["device"] as? String).flatMap { Device(rawValue: $0.lowercased()) }
        return (ep, providerOptions, device)
    }

    fileprivate func decodeChatOptions(_ o: [String: Any]) -> ChatSessionOptions {
        return ChatSessionOptions(
            systemPrompt: o["system_prompt"] as? String,
            temperature: o["temperature"] as? Double,
            topP: o["top_p"] as? Double,
            topK: o["top_k"] as? Int,
            maxOutputTokens: o["max_output_tokens"] as? Int,
            seed: (o["seed"] as? NSNumber)?.int64Value,
            keepHistory: (o["keep_history"] as? Bool) ?? true
        )
    }

    fileprivate func decodeAudioOptions(_ o: [String: Any]) -> AudioSessionOptions {
        return AudioSessionOptions(
            language: o["language"] as? String,
            temperature: o["temperature"] as? Double,
            maxOutputTokens: o["max_output_tokens"] as? Int
        )
    }

    fileprivate func decodeChatRequest(_ json: String) throws -> ChatRequest {
        let o = try parseObject(json)
        let rawMessages = (o["messages"] as? [[String: Any]]) ?? []
        let messages: [ChatMessage] = rawMessages.compactMap { msg in
            guard let roleRaw = msg["role"] as? String,
                  let role = ChatMessage.Role(rawValue: roleRaw) else { return nil }
            // Match the Kotlin binding's Chat surface: content is a plain
            // string (multi-part content is not exercised through the RN
            // wire format yet).
            let text = (msg["content"] as? String) ?? ""
            return ChatMessage(role: role, text: text)
        }
        let tools: [ChatTool]? = (o["tools"] as? [[String: Any]]).map { arr in
            arr.compactMap { t in
                guard let name = t["name"] as? String else { return nil }
                let description = t["description"] as? String
                let parameters: String
                if let obj = t["parameters"] {
                    if JSONSerialization.isValidJSONObject(obj),
                       let d = try? JSONSerialization.data(withJSONObject: obj),
                       let s = String(data: d, encoding: .utf8) {
                        parameters = s
                    } else {
                        parameters = "{}"
                    }
                } else {
                    parameters = "{}"
                }
                return ChatTool(name: name, description: description, parametersJSON: parameters)
            }
        }
        return ChatRequest(
            messages: messages,
            tools: tools,
            toolChoice: o["tool_choice"] as? String,
            temperature: o["temperature"] as? Double,
            topP: o["top_p"] as? Double,
            topK: o["top_k"] as? Int,
            maxOutputTokens: o["max_output_tokens"] as? Int,
            seed: (o["seed"] as? NSNumber)?.int64Value,
            stopSequences: o["stop_sequences"] as? [String]
        )
    }

    fileprivate func encodeChatCompletion(_ c: ChatCompletion) throws -> String {
        var payload: [String: Any] = [
            "text": c.text ?? "",
            "finish_reason": c.finishReason.rawValue,
        ]
        if let usage = c.usage {
            payload["usage"] = [
                "prompt_tokens": usage.promptTokens,
                "completion_tokens": usage.completionTokens,
                "total_tokens": usage.totalTokens,
            ]
        }
        if let toolCalls = c.toolCalls {
            payload["tool_calls"] = toolCalls.map { tc -> [String: Any] in
                [
                    "call_id": tc.callId,
                    "name": tc.name,
                    "arguments": tc.arguments,
                ]
            }
        }
        return jsonString(payload)
    }

    fileprivate func decodeToolResults(_ json: String) throws -> [ToolResult] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw FoundryLocalError(code: .invalidArgument, message: "Expected JSON array of tool results")
        }
        return arr.compactMap { obj in
            guard let callId = obj["call_id"] as? String else { return nil }
            let raw = obj["result"]
            let resultStr: String
            if let s = raw as? String {
                resultStr = s
            } else if let raw, JSONSerialization.isValidJSONObject(raw),
                      let d = try? JSONSerialization.data(withJSONObject: raw),
                      let s = String(data: d, encoding: .utf8) {
                resultStr = s
            } else {
                resultStr = "{}"
            }
            return ToolResult(callId: callId, result: resultStr)
        }
    }

    fileprivate enum TranscribeRequest {
        case file(path: String, language: String?, translate: Bool)
        case inMemory(base64: String, format: String, sampleRate: Int, channels: Int, language: String?, translate: Bool)
        case streaming(language: String?, translate: Bool)
    }

    fileprivate func decodeTranscribeRequest(_ json: String) throws -> TranscribeRequest {
        let o = try parseObject(json)
        let language = o["language"] as? String
        let translate = (o["translate"] as? Bool) ?? false
        if (o["streaming"] as? Bool) == true {
            return .streaming(language: language, translate: translate)
        }
        if let path = o["path"] as? String {
            return .file(path: path, language: language, translate: translate)
        }
        return .inMemory(
            base64: (o["data_base64"] as? String) ?? "",
            format: (o["format"] as? String) ?? "pcm",
            sampleRate: (o["sample_rate"] as? Int) ?? 16000,
            channels: (o["channels"] as? Int) ?? 1,
            language: language,
            translate: translate
        )
    }

    fileprivate func encodeTranscription(_ r: TranscriptionResult) throws -> String {
        var payload: [String: Any] = ["text": r.text]
        if let lang = r.language { payload["language"] = lang }
        payload["segments"] = (r.segments ?? []).map { seg -> [String: Any] in
            var segPayload: [String: Any] = [
                "text": seg.text,
                "start_time_ms": seg.startTimeMs,
                "end_time_ms": seg.endTimeMs,
            ]
            if let lang = seg.language { segPayload["language"] = lang }
            return segPayload
        }
        return jsonString(payload)
    }

    fileprivate func decodeEmbedInputs(_ json: String) throws -> [String] {
        let o = try parseObject(json)
        return (o["inputs"] as? [String]) ?? []
    }

    fileprivate func encodeEmbedding(_ r: EmbeddingResult) throws -> String {
        let payload: [String: Any] = [
            "dimensions": r.dimensions,
            "embeddings": r.embeddings.map { row in row.map { NSNumber(value: $0) } },
        ]
        return jsonString(payload)
    }

    fileprivate func encodeChatDelta(_ delta: ChatDelta) -> [AnyHashable: Any] {
        switch delta {
        case .text(let t):
            return ["kind": "text", "text": t]
        case .reasoning(let t):
            return ["kind": "reasoning", "text": t]
        case .toolCall(let call):
            return [
                "kind": "toolCall",
                "toolCall": [
                    "callId": call.callId,
                    "name": call.name,
                    "argumentsJson": call.arguments,
                ],
            ]
        case .usage(let counts):
            return [
                "kind": "usage",
                "usage": [
                    "promptTokens": counts.promptTokens,
                    "completionTokens": counts.completionTokens,
                ],
            ]
        case .completed(let reason, _):
            return ["kind": "completed", "reason": reason.rawValue]
        }
    }

    fileprivate func encodeSpeechDelta(_ delta: SpeechDelta) -> [AnyHashable: Any] {
        switch delta {
        case .partial(let seg):
            return [
                "kind": "speechPartial",
                "text": seg.text,
                "startTimeMs": seg.startMilliseconds,
                "endTimeMs": seg.endMilliseconds,
            ]
        case .final(let seg):
            return [
                "kind": "speechFinal",
                "text": seg.text,
                "startTimeMs": seg.startMilliseconds,
                "endTimeMs": seg.endMilliseconds,
            ]
        }
    }
}
