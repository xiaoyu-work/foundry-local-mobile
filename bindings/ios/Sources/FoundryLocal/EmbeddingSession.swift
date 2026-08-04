// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import Foundation
import FoundryLocalCore

/// A text-embedding session over a loaded embedding model.
public final class EmbeddingSession: @unchecked Sendable {
    public let handle: flm_session
    private let released = ManagedAtomicBool()

    init(model: Model) throws {
        var out: flm_session = 0
        let json = "{\"type\":\"embedding\"}"
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

    /// Compute embeddings for one or more input strings.
    public func embed(_ inputs: [String]) async throws -> EmbeddingResult {
        let payload: [String: Any] = ["inputs": inputs]
        let json = payload.jsonString() ?? "{\"inputs\":[]}"
        return try await runAsyncJob(
            decode: { job in
                let text = try takeJobResultJSON(job)
                return try flmJSONDecoder.decode(EmbeddingResult.self, from: Data(text.utf8))
            },
            submit: { [handle] userData, _, onComplete, outJob in
                json.withCString { jsonPtr in
                    flm_session_embed_async(handle, jsonPtr, onComplete, userData, outJob)
                }
            }
        )
    }
}
