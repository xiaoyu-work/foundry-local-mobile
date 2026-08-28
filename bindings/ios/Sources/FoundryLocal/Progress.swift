// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import Foundation
import FoundryLocalMobile

/// Snapshot of a long-running operation, mirroring `flm_progress`. Progress values from
/// the ABI are borrowed C strings; every field here is copied out before the callback
/// returns so the value can safely leave the callback thread.
public struct Progress: Sendable, Equatable {
    public let percent: Float
    public let completedBytes: Int64?
    public let totalBytes: Int64?
    public let bytesPerSecond: Int64?
    public let etaMilliseconds: Int64?
    /// Named phase, for example "validating" or "loading".
    public let stage: String
    /// Item currently being processed. May be empty.
    public let detail: String

    init(cValue: flm_progress) {
        self.percent = cValue.percent
        self.completedBytes = cValue.completed_bytes == Int64(FLM_UNKNOWN_SIZE) ? nil : cValue.completed_bytes
        self.totalBytes = cValue.total_bytes == Int64(FLM_UNKNOWN_SIZE) ? nil : cValue.total_bytes
        self.bytesPerSecond = cValue.bytes_per_second == Int64(FLM_UNKNOWN_SIZE) ? nil : cValue.bytes_per_second
        self.etaMilliseconds = cValue.eta_ms == Int64(FLM_UNKNOWN_SIZE) ? nil : cValue.eta_ms
        self.stage = cValue.stage.map { String(cString: $0) } ?? ""
        self.detail = cValue.detail.map { String(cString: $0) } ?? ""
    }
}
