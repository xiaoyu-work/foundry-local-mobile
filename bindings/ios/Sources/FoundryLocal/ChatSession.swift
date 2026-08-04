// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import Foundation
import FoundryLocalMobile

/// Options for a chat session, mirroring the JSON schema on `flm_session_create` /
/// `flm_session_set_options`.
public struct ChatSessionOptions: Sendable {
    public var systemPrompt: String?
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var maxOutputTokens: Int?
    public var seed: Int64?
    public var keepHistory: Bool = true

    public init(
        systemPrompt: String? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        maxOutputTokens: Int? = nil,
        seed: Int64? = nil,
        keepHistory: Bool = true
    ) {
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.maxOutputTokens = maxOutputTokens
        self.seed = seed
        self.keepHistory = keepHistory
    }

    func encodeAsJSON() -> String {
        var payload: [String: Any] = ["type": "chat", "keep_history": keepHistory]
        if let systemPrompt { payload["system_prompt"] = systemPrompt }
        if let temperature { payload["temperature"] = temperature }
        if let topP { payload["top_p"] = topP }
        if let topK { payload["top_k"] = topK }
        if let maxOutputTokens { payload["max_output_tokens"] = maxOutputTokens }
        if let seed { payload["seed"] = seed }
        return payload.jsonString() ?? "{}"
    }
}

/// A chat completion session bound to a loaded model. Streams token deltas through
/// ``completeStreaming``, or awaits the full text through ``complete``.
///
/// Session handles hold KV cache and generator state; release them promptly with
/// ``close()`` (called automatically on `deinit`) once the conversation is finished.
public final class ChatSession: @unchecked Sendable {
    public let handle: flm_session
    private let released = ManagedAtomicBool()

    init(model: Model, options: ChatSessionOptions) throws {
        var out: flm_session = 0
        let json = options.encodeAsJSON()
        let status = json.withCString { flm_session_create(model.handle, $0, &out) }
        if status != FLM_OK {
            throw FoundryLocalError.fromCurrent(status: status)
        }
        self.handle = out
    }

    deinit { close() }

    /// Release the session. Cancels any in-flight request and frees the KV cache.
    public func close() {
        if released.exchange(true) { return }
        _ = flm_session_release(handle)
    }

    /// Update sampling settings without recreating the session.
    public func setOptions(_ options: ChatSessionOptions) throws {
        let json = options.encodeAsJSON()
        let status = json.withCString { flm_session_set_options(handle, $0) }
        if status != FLM_OK {
            throw FoundryLocalError.fromCurrent(status: status)
        }
    }

    // MARK: - Completion

    /// Send a text prompt as a single user turn and stream the reply.
    public func completeStreaming(_ prompt: String) -> AsyncThrowingStream<ChatDelta, Error> {
        let request = ChatRequest(messages: [.user(prompt)])
        return streamRequest(request)
    }

    /// Send a fully-shaped request (multi-turn history, tools, images) and stream the
    /// reply.
    public func completeStreaming(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
        streamRequest(request)
    }

    /// Non-streaming variant: awaits the whole reply and returns it.
    public func complete(_ prompt: String) async throws -> ChatCompletion {
        let request = ChatRequest(messages: [.user(prompt)])
        return try await completeRequest(request)
    }

    /// Non-streaming variant with a fully-shaped request.
    public func complete(_ request: ChatRequest) async throws -> ChatCompletion {
        try await completeRequest(request)
    }

    /// Submit results for tool calls the model previously emitted and resume the turn.
    /// Streaming reply, as with ``completeStreaming``.
    public func submitToolResults(_ results: [ToolResult]) -> AsyncThrowingStream<ChatDelta, Error> {
        let json: String
        do {
            json = try encodeToolResults(results)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return runStreamingJob(
            decodeDelta: { ChatDelta.from(cValue: $0) },
            submit: { [handle] userData, onDelta, onComplete, outJob in
                json.withCString { jsonPtr in
                    flm_session_submit_tool_results_async(handle, jsonPtr, onDelta, onComplete, userData, outJob)
                }
            }
        )
    }

    // MARK: - History

    /// Number of completed user/assistant turn pairs in the session history.
    public var turnCount: Int {
        var count: Int = 0
        _ = flm_session_get_turn_count(handle, &count)
        return count
    }

    /// Drop the last `count` turns from history and rewind the generator state.
    public func undoTurns(_ count: Int) throws {
        let status = flm_session_undo_turns(handle, count)
        if status != FLM_OK {
            throw FoundryLocalError.fromCurrent(status: status)
        }
    }

    /// Clear the conversation history, keeping options.
    public func clearHistory() throws {
        let status = flm_session_clear_history(handle)
        if status != FLM_OK {
            throw FoundryLocalError.fromCurrent(status: status)
        }
    }

    /// Serialise history so it can be restored after the process is killed — routine
    /// on iOS where the OS reclaims backgrounded apps.
    public func exportHistoryJSON() throws -> String {
        try readJSON { flm_session_export_history_json(handle, $0) }
    }

    /// Reinstall history previously produced by ``exportHistoryJSON``.
    public func restoreHistory(fromJSON json: String) throws {
        let status = json.withCString { flm_session_restore_history_json(handle, $0) }
        if status != FLM_OK {
            throw FoundryLocalError.fromCurrent(status: status)
        }
    }

    // MARK: - Internal

    private func streamRequest(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
        let json: String
        do {
            json = try String(data: flmJSONEncoder.encode(request), encoding: .utf8) ?? "{}"
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return runStreamingJob(
            decodeDelta: { ChatDelta.from(cValue: $0) },
            submit: { [handle] userData, onDelta, onComplete, outJob in
                json.withCString { jsonPtr in
                    flm_session_complete_async(handle, jsonPtr, onDelta, onComplete, userData, outJob)
                }
            }
        )
    }

    private func completeRequest(_ request: ChatRequest) async throws -> ChatCompletion {
        let data = try flmJSONEncoder.encode(request)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return try await runAsyncJob(
            decode: { job in
                let text = try takeJobResultJSON(job)
                return try flmJSONDecoder.decode(ChatCompletion.self, from: Data(text.utf8))
            },
            submit: { [handle] userData, _, onComplete, outJob in
                json.withCString { jsonPtr in
                    // Pass a NULL delta callback: the ABI aggregates into the result JSON.
                    flm_session_complete_async(handle, jsonPtr, nil, onComplete, userData, outJob)
                }
            }
        )
    }

    private func encodeToolResults(_ results: [ToolResult]) throws -> String {
        let arr = results.map { ["call_id": $0.callId, "result": $0.result] }
        let data = try JSONSerialization.data(withJSONObject: arr, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}

/// One tool execution result to feed back into a conversation.
public struct ToolResult: Sendable {
    public var callId: String
    /// Serialised result the model will read. Free-form JSON string per the ABI.
    public var result: String

    public init(callId: String, result: String) {
        self.callId = callId
        self.result = result
    }
}
