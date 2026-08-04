// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.foundrylocal.reactnative

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.ReactContext
import com.facebook.react.bridge.WritableMap
import com.facebook.react.modules.core.DeviceEventManagerModule
import com.microsoft.ai.foundry.local.mobile.Delta
import com.microsoft.ai.foundry.local.mobile.FinishReason
import com.microsoft.ai.foundry.local.mobile.Progress

/**
 * Event names emitted through `NativeEventEmitter`.
 *
 * The JS side subscribes to these on a per-`subscriptionId` basis; the ids
 * are minted on the JS side and passed in to the streaming call. Filtering
 * happens in JS because the emitter has no built-in topic support.
 */
internal object EventNames {
    const val DELTA = "FoundryLocal:delta"
    const val PROGRESS = "FoundryLocal:progress"
    const val END = "FoundryLocal:end"
    const val ERROR = "FoundryLocal:error"
}

/**
 * Turns typed Kotlin objects from the underlying binding into the loosely
 * typed `WritableMap` structures RN's event emitter expects. Field names
 * mirror the TypeScript {@link Delta} / {@link Progress} types so no
 * per-kind decoding is needed on the JS side.
 */
internal object EventPayloads {
    fun progress(subscriptionId: String, p: Progress): WritableMap {
        val progress = Arguments.createMap().apply {
            putDouble("percent", p.percent.toDouble())
            putDouble("completedBytes", p.completedBytes.toDouble())
            putDouble("totalBytes", p.totalBytes.toDouble())
            putDouble("bytesPerSecond", p.bytesPerSecond.toDouble())
            putDouble("etaMs", p.etaMs.toDouble())
            if (p.stage != null) putString("stage", p.stage) else putNull("stage")
            if (p.detail != null) putString("detail", p.detail) else putNull("detail")
        }
        return Arguments.createMap().apply {
            putString("subscriptionId", subscriptionId)
            putMap("progress", progress)
        }
    }

    fun delta(subscriptionId: String, d: Delta): WritableMap {
        val encoded: WritableMap = when (d) {
            is Delta.Text -> Arguments.createMap().apply {
                putString("kind", "text")
                putString("text", d.text)
            }
            is Delta.Reasoning -> Arguments.createMap().apply {
                putString("kind", "reasoning")
                putString("text", d.text)
            }
            is Delta.ToolCall -> Arguments.createMap().apply {
                putString("kind", "toolCall")
                putMap("toolCall", Arguments.createMap().apply {
                    putString("callId", d.callId)
                    putString("name", d.name)
                    putString("argumentsJson", d.argumentsJson)
                })
            }
            is Delta.SpeechPartial -> Arguments.createMap().apply {
                putString("kind", "speechPartial")
                putString("text", d.text)
                putDouble("startTimeMs", d.startTimeMs.toDouble())
                putDouble("endTimeMs", d.endTimeMs.toDouble())
            }
            is Delta.SpeechFinal -> Arguments.createMap().apply {
                putString("kind", "speechFinal")
                putString("text", d.text)
                putDouble("startTimeMs", d.startTimeMs.toDouble())
                putDouble("endTimeMs", d.endTimeMs.toDouble())
            }
            is Delta.Usage -> Arguments.createMap().apply {
                putString("kind", "usage")
                putMap("usage", Arguments.createMap().apply {
                    putDouble("promptTokens", d.promptTokens.toDouble())
                    putDouble("completionTokens", d.completionTokens.toDouble())
                })
            }
            is Delta.Completed -> Arguments.createMap().apply {
                putString("kind", "completed")
                putString("reason", finishReasonToString(d.reason))
            }
        }
        return Arguments.createMap().apply {
            putString("subscriptionId", subscriptionId)
            putMap("delta", encoded)
        }
    }

    fun end(subscriptionId: String, resultJson: String?): WritableMap =
        Arguments.createMap().apply {
            putString("subscriptionId", subscriptionId)
            if (resultJson != null) putString("resultJson", resultJson) else putNull("resultJson")
        }

    fun error(subscriptionId: String, status: Int, message: String?, detail: String?): WritableMap =
        Arguments.createMap().apply {
            putString("subscriptionId", subscriptionId)
            putInt("status", status)
            putString("message", message ?: "")
            if (detail != null) putString("detail", detail) else putNull("detail")
        }

    private fun finishReasonToString(r: FinishReason): String = when (r) {
        FinishReason.NONE -> "none"
        FinishReason.STOP -> "stop"
        FinishReason.LENGTH -> "length"
        FinishReason.TOOL_CALLS -> "tool_calls"
        FinishReason.CANCELLED -> "cancelled"
        FinishReason.ERROR -> "error"
        FinishReason.UNKNOWN -> "unknown"
    }
}

internal fun ReactContext.emit(eventName: String, payload: WritableMap) {
    // getJSModule can be null before the JS bundle attaches; drop the event
    // rather than crashing.
    val emitter = try {
        getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
    } catch (_: Throwable) {
        null
    }
    emitter?.emit(eventName, payload)
}
