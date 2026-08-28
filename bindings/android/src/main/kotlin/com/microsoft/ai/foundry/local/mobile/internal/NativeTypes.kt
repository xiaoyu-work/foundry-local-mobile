// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.mobile.internal

/**
 * Wire-shaped mirror of `flm_progress`. Instantiated by JNI and immediately
 * translated into the public [com.microsoft.ai.foundry.local.mobile.Progress]
 * data class.
 *
 * Kept as a plain class (not a Kotlin data class) so its constructor signature
 * matches the JNI method descriptor exactly.
 */
public class NativeProgress internal constructor(
    @JvmField public val percent: Float,
    @JvmField public val completedBytes: Long,
    @JvmField public val totalBytes: Long,
    @JvmField public val bytesPerSecond: Long,
    @JvmField public val etaMs: Long,
    @JvmField public val stage: String?,
    @JvmField public val detail: String?,
)

/**
 * Wire-shaped mirror of `flm_delta`.
 */
public class NativeDelta internal constructor(
    @JvmField public val kind: Int,
    @JvmField public val text: String?,
    @JvmField public val toolCallId: String?,
    @JvmField public val toolName: String?,
    @JvmField public val toolArgumentsJson: String?,
    @JvmField public val startTimeMs: Long,
    @JvmField public val endTimeMs: Long,
    @JvmField public val promptTokens: Long,
    @JvmField public val completionTokens: Long,
    @JvmField public val finishReason: Int,
)
