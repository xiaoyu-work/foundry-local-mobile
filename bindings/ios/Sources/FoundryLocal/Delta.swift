// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import Foundation
import FoundryLocalCore

/// One event from a streaming inference session — a token fragment, a reasoning trace,
/// a tool call the model wants executed, a speech hypothesis or a terminal marker.
///
/// Mirrors `flm_delta`, but every `const char*` in the C struct is borrowed and valid
/// only for the callback lifetime, so this type copies each string out.
public enum ChatDelta: Sendable, Equatable {
    /// Assistant text fragment. Append to a running buffer for typewriter UIs.
    case text(String)

    /// Chain-of-thought fragment from a reasoning model.
    case reasoning(String)

    /// The model has requested a tool. Execute it, then feed the result back with
    /// ``ChatSession/submitToolResults``.
    case toolCall(ToolCall)

    /// Rolling token counters. Emitted periodically during long completions.
    case usage(TokenCounts)

    /// Terminal marker. No further events will follow.
    case completed(FinishReason, TokenCounts?)

    public struct TokenCounts: Sendable, Equatable {
        public let promptTokens: Int64
        public let completionTokens: Int64
    }

    static func from(cValue delta: UnsafePointer<flm_delta>) -> ChatDelta? {
        let value = delta.pointee
        switch value.kind {
        case FLM_DELTA_TEXT:
            let text = copyDeltaText(value.text, length: value.text_length) ?? ""
            return .text(text)
        case FLM_DELTA_REASONING:
            let text = copyDeltaText(value.text, length: value.text_length) ?? ""
            return .reasoning(text)
        case FLM_DELTA_TOOL_CALL:
            let id = value.tool_call_id.map { String(cString: $0) } ?? ""
            let name = value.tool_name.map { String(cString: $0) } ?? ""
            let args = value.tool_arguments_json.map { String(cString: $0) } ?? "{}"
            return .toolCall(ToolCall(callId: id, name: name, argumentsJson: args))
        case FLM_DELTA_USAGE:
            return .usage(TokenCounts(promptTokens: value.prompt_tokens, completionTokens: value.completion_tokens))
        case FLM_DELTA_COMPLETED:
            let counts = TokenCounts(promptTokens: value.prompt_tokens, completionTokens: value.completion_tokens)
            return .completed(FinishReason(cValue: value.finish_reason), counts)
        default:
            return nil
        }
    }
}

/// One event from a live transcription session.
public enum SpeechDelta: Sendable, Equatable {
    /// Interim hypothesis, replacing the previous partial for this segment.
    case partial(SpeechSegment)
    /// Stable segment; safe to persist.
    case final(SpeechSegment)

    public struct SpeechSegment: Sendable, Equatable {
        public let text: String
        public let startMilliseconds: Int64
        public let endMilliseconds: Int64
    }

    static func from(cValue delta: UnsafePointer<flm_delta>) -> SpeechDelta? {
        let value = delta.pointee
        let text = copyDeltaText(value.text, length: value.text_length) ?? ""
        let segment = SpeechSegment(
            text: text,
            startMilliseconds: value.start_time_ms,
            endMilliseconds: value.end_time_ms
        )
        switch value.kind {
        case FLM_DELTA_SPEECH_PARTIAL:
            return .partial(segment)
        case FLM_DELTA_SPEECH_FINAL:
            return .final(segment)
        default:
            return nil
        }
    }
}

/// The ABI hands back UTF-8 text as `(pointer, length)`, not necessarily
/// null-terminated. Copy into a Swift `String` on the callback thread; the buffer is
/// invalidated when the callback returns.
private func copyDeltaText(_ ptr: UnsafePointer<CChar>?, length: Int) -> String? {
    guard let ptr, length > 0 else { return nil }
    let bytes = UnsafeRawPointer(ptr).bindMemory(to: UInt8.self, capacity: length)
    let buffer = UnsafeBufferPointer(start: bytes, count: length)
    return String(decoding: buffer, as: UTF8.self)
}
