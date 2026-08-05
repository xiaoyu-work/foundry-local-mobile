// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import Foundation
import FoundryLocalMobile

/// Options for a speech-to-text session.
public struct AudioSessionOptions: Sendable {
    /// BCP-47 language tag, e.g. `"en"` or `"en-US"`. When `nil` the model auto-detects.
    public var language: String?
    public var temperature: Double?
    public var maxOutputTokens: Int?

    public init(language: String? = nil, temperature: Double? = nil, maxOutputTokens: Int? = nil) {
        self.language = language
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
    }

    func encodeAsJSON() -> String {
        var payload: [String: Any] = ["type": "audio"]
        if let language { payload["language"] = language }
        if let temperature { payload["temperature"] = temperature }
        if let maxOutputTokens { payload["max_output_tokens"] = maxOutputTokens }
        return payload.jsonString() ?? "{}"
    }
}

/// A speech-to-text session over a loaded speech model.
///
/// Two modes:
///   * **File**: pass a WAV/MP3 path or base64 blob to ``transcribeStreaming`` and get
///     partial + final segments back.
///   * **Streaming microphone**: start the session with
///     ``startStreamingTranscription``, then push PCM chunks via ``pushAudio``.
public final class AudioSession: @unchecked Sendable {
    public let handle: flm_session
    private let released = ManagedAtomicBool()

    init(model: Model, options: AudioSessionOptions) throws {
        var out: flm_session = 0
        let json = options.encodeAsJSON()
        let status = json.withCString { flm_session_create(model.handle, $0, &out) }
        if status != FLM_OK {
            throw FoundryLocalError.fromCurrent(status: status)
        }
        self.handle = out
    }

    deinit { close() }

    public func close() {
        if released.exchange(true) { return }
        _ = flm_session_release(handle)
    }

    // MARK: - File / blob transcription

    /// Transcribe an audio file at a filesystem path, streaming partial and final
    /// segments.
    public func transcribeStreaming(
        path: String,
        language: String? = nil,
        translate: Bool = false
    ) -> AsyncThrowingStream<SpeechDelta, any Error> {
        var payload: [String: Any] = ["path": path, "translate": translate]
        if let language { payload["language"] = language }
        return transcribeStream(payload: payload)
    }

    /// Transcribe raw PCM (or any format the runtime supports) given as base64 data.
    public func transcribeStreaming(
        base64: String,
        format: String,
        sampleRate: Int,
        channels: Int = 1,
        language: String? = nil,
        translate: Bool = false
    ) -> AsyncThrowingStream<SpeechDelta, any Error> {
        var payload: [String: Any] = [
            "data_base64": base64,
            "format": format,
            "sample_rate": sampleRate,
            "channels": channels,
            "translate": translate,
        ]
        if let language { payload["language"] = language }
        return transcribeStream(payload: payload)
    }

    /// Non-streaming file transcription. Await the full result.
    public func transcribe(path: String, language: String? = nil, translate: Bool = false) async throws -> TranscriptionResult {
        var payload: [String: Any] = ["path": path, "translate": translate]
        if let language { payload["language"] = language }
        let json = payload.jsonString() ?? "{}"
        return try await runAsyncJob(
            decode: { job in
                let text = try takeJobResultJSON(job)
                return try flmJSONDecoder.decode(TranscriptionResult.self, from: Data(text.utf8))
            },
            submit: { [handle] userData, _, onComplete, outJob in
                json.withCString { jsonPtr in
                    flm_session_transcribe_async(handle, jsonPtr, nil, onComplete, userData, outJob)
                }
            }
        )
    }

    // MARK: - Streaming microphone

    /// Start a live PCM transcription. Feed chunks with ``pushAudio``; partial and
    /// final segments arrive on the returned stream.
    ///
    /// Once you have sent the last chunk with `isFinal == true`, the stream will
    /// finish naturally after the model flushes its remaining segments.
    public func startStreamingTranscription(
        language: String? = nil,
        translate: Bool = false
    ) -> AsyncThrowingStream<SpeechDelta, any Error> {
        var payload: [String: Any] = ["streaming": true, "translate": translate]
        if let language { payload["language"] = language }
        return transcribeStream(payload: payload)
    }

    /// Push a chunk of PCM into a live transcription. Call with `isFinal: true` on
    /// the last chunk to flush the tail.
    public func pushAudio(
        _ data: Data,
        sampleRate: Int32,
        channels: Int32,
        isFinal: Bool
    ) throws {
        try data.withUnsafeBytes { rawBuffer in
            let base = rawBuffer.baseAddress
            let status = flm_session_push_audio(
                handle, base, data.count, sampleRate, channels, isFinal ? 1 : 0
            )
            if status != FLM_OK {
                throw FoundryLocalError.fromCurrent(status: status)
            }
        }
    }

    // MARK: - Internal

    private func transcribeStream(payload: [String: Any]) -> AsyncThrowingStream<SpeechDelta, any Error> {
        guard let json = payload.jsonString() else {
            return AsyncThrowingStream { $0.finish(throwing: FoundryLocalError(code: .invalidArgument, message: "failed to encode transcription request")) }
        }
        return runStreamingJob(
            decodeDelta: { SpeechDelta.from(cValue: $0) },
            submit: { [handle] userData, onDelta, onComplete, outJob in
                json.withCString { jsonPtr in
                    flm_session_transcribe_async(handle, jsonPtr, onDelta, onComplete, userData, outJob)
                }
            }
        )
    }
}
