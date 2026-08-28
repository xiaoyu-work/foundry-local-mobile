// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.mobile

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

// -----------------------------------------------------------------------------
// Configuration
// -----------------------------------------------------------------------------

/**
 * Options passed to [FoundryLocal.create]. Matches the JSON schema documented
 * on `flm_manager_create`.
 *
 * `appDataDir` and the other filesystem paths are filled in automatically from
 * the supplied [android.content.Context] and normally do not need overriding.
 */
public data class FoundryLocalConfig(
    /** App-defined name used for logging and cache namespacing. */
    val appName: String,
    /** Override the sandbox path (`context.filesDir/foundry` by default). */
    val appDataDir: String? = null,
    /** Default log level; also settable at runtime via [FoundryLocal.setLogLevel]. */
    val logLevel: LogLevel = LogLevel.WARNING,
    val autoUnloadOnBackground: Boolean = true,
    /** 0 = derive from the number of CPU cores. */
    val jobPoolThreads: Int = 0,
)

public enum class LogLevel(public val nativeValue: Int) {
    VERBOSE(0), DEBUG(1), INFO(2), WARNING(3), ERROR(4), FATAL(5), OFF(6),
}

// -----------------------------------------------------------------------------
// Device profile
// -----------------------------------------------------------------------------

@Serializable
public data class DeviceProfile(
    val platform: String,
    @SerialName("os_version") val osVersion: String,
    @SerialName("device_model") val deviceModel: String,
    val soc: String? = null,
    val abi: String,
    @SerialName("cpu_cores") val cpuCores: Int,
    @SerialName("total_memory_bytes") val totalMemoryBytes: Long,
    @SerialName("available_memory_bytes") val availableMemoryBytes: Long,
    @SerialName("available_storage_bytes") val availableStorageBytes: Long,
    @SerialName("has_npu") val hasNpu: Boolean = false,
    @SerialName("has_gpu") val hasGpu: Boolean = false,
    @SerialName("execution_providers") val executionProviders: List<ExecutionProviderInfo> = emptyList(),
    @SerialName("thermal_state") val thermalState: String? = null,
    @SerialName("low_power_mode") val lowPowerMode: Boolean = false,
    val network: NetworkKind = NetworkKind.UNKNOWN,
) {
    /**
     * Concise human-readable summary of the ABI, core count and every
     * currently-available execution provider, e.g.
     * `arm64-v8a, 8 cores, EPs: QNN (NPU), XNNPACK (CPU)`.
     */
    public val summary: String
        get() {
            val eps = executionProviders
                .filter { it.available }
                .joinToString(", ") { "${it.name} (${it.device})" }
                .ifBlank { "CPU only" }
            return "$abi, $cpuCores cores, EPs: $eps"
        }
}

@Serializable
public data class ExecutionProviderInfo(
    /** Provider name, e.g. `QNN`, `CoreML`, `XNNPACK`, `CPU`. */
    val name: String,
    /** Placement device this provider targets. */
    val device: FlmDevice,
    /** `true` if the provider is registered with the runtime and can be selected. */
    val available: Boolean,
    /** Lower values are preferred when the SDK ranks providers. */
    val priority: Int,
)

public enum class FlmDevice { UNKNOWN, CPU, GPU, NPU }

public enum class NetworkKind {
    @SerialName("unknown") UNKNOWN,
    @SerialName("unmetered") UNMETERED,
    @SerialName("metered") METERED,
    @SerialName("offline") OFFLINE,
}

// -----------------------------------------------------------------------------
// Model metadata
// -----------------------------------------------------------------------------

@Serializable
public data class ModelInfo(
    val id: String,
    val alias: String? = null,
    val name: String,
    @SerialName("display_name") val displayName: String? = null,
    val version: Int = 0,
    val publisher: String? = null,
    val license: String? = null,
    val task: String? = null,
    val device: FlmDevice = FlmDevice.UNKNOWN,
    @SerialName("execution_provider") val executionProvider: String? = null,
    @SerialName("file_size_bytes") val fileSizeBytes: Long = -1,
    @SerialName("context_length") val contextLength: Int = 0,
    @SerialName("max_output_tokens") val maxOutputTokens: Int = 0,
    @SerialName("supports_tool_calling") val supportsToolCalling: Boolean = false,
    @SerialName("supports_reasoning") val supportsReasoning: Boolean = false,
    @SerialName("input_modalities") val inputModalities: List<String> = emptyList(),
    @SerialName("output_modalities") val outputModalities: List<String> = emptyList(),
    @SerialName("is_cached") val isCached: Boolean = false,
    @SerialName("is_loaded") val isLoaded: Boolean = false,
    @SerialName("prompt_templates") val promptTemplates: Map<String, String>? = null,
)

// -----------------------------------------------------------------------------
// Session options
// -----------------------------------------------------------------------------

@Serializable
public data class ChatOptions(
    @SerialName("system_prompt") val systemPrompt: String? = null,
    val temperature: Float? = null,
    @SerialName("top_p") val topP: Float? = null,
    @SerialName("top_k") val topK: Int? = null,
    @SerialName("max_output_tokens") val maxOutputTokens: Int? = null,
    val seed: Int? = null,
    @SerialName("keep_history") val keepHistory: Boolean = true,
)

@Serializable
public data class AudioOptions(
    val language: String? = null,
    @SerialName("max_output_tokens") val maxOutputTokens: Int? = null,
)

@Serializable
public data class EmbeddingOptions(
    val extra: JsonElement? = null,
)

// -----------------------------------------------------------------------------
// Streaming
// -----------------------------------------------------------------------------

public data class Progress(
    val percent: Float,
    val completedBytes: Long,
    val totalBytes: Long,
    val bytesPerSecond: Long,
    val etaMs: Long,
    val stage: String?,
    val detail: String?,
) {
    /** The same value as [percent] expressed as a fraction in `[0f, 1f]`. */
    public val fraction: Float
        get() = (percent / 100f).coerceIn(0f, 1f)

    public companion object {
        internal fun from(n: com.microsoft.ai.foundry.local.mobile.internal.NativeProgress): Progress = Progress(
            percent = n.percent,
            completedBytes = n.completedBytes,
            totalBytes = n.totalBytes,
            bytesPerSecond = n.bytesPerSecond,
            etaMs = n.etaMs,
            stage = n.stage,
            detail = n.detail,
        )
    }
}

public sealed class Delta {
    /** Assistant text fragment. */
    public data class Text(val text: String) : Delta()

    /** Chain-of-thought fragment from a reasoning model. */
    public data class Reasoning(val text: String) : Delta()

    /**
     * A complete tool call the model wants executed. `argumentsJson` is the
     * raw JSON payload the model produced.
     */
    public data class ToolCall(
        val callId: String,
        val name: String,
        val argumentsJson: String,
    ) : Delta()

    /** Speech transcription hypothesis; replaces the previous partial. */
    public data class SpeechPartial(
        val text: String,
        val startTimeMs: Long,
        val endTimeMs: Long,
    ) : Delta()

    /** Speech transcription segment is stable. */
    public data class SpeechFinal(
        val text: String,
        val startTimeMs: Long,
        val endTimeMs: Long,
    ) : Delta()

    /** Token accounting update. */
    public data class Usage(
        val promptTokens: Long,
        val completionTokens: Long,
    ) : Delta()

    /** Terminal event for the request. */
    public data class Completed(val reason: FinishReason) : Delta()

    public companion object {
        internal fun from(n: com.microsoft.ai.foundry.local.mobile.internal.NativeDelta): Delta = when (n.kind) {
            0 -> Text(n.text ?: "")
            1 -> Reasoning(n.text ?: "")
            2 -> ToolCall(
                callId = n.toolCallId ?: "",
                name = n.toolName ?: "",
                argumentsJson = n.toolArgumentsJson ?: "{}",
            )
            3 -> SpeechPartial(n.text ?: "", n.startTimeMs, n.endTimeMs)
            4 -> SpeechFinal(n.text ?: "", n.startTimeMs, n.endTimeMs)
            5 -> Usage(n.promptTokens, n.completionTokens)
            6 -> Completed(FinishReason.fromInt(n.finishReason))
            else -> Text(n.text ?: "")
        }
    }
}

public enum class FinishReason(public val nativeValue: Int) {
    NONE(0),
    STOP(1),
    LENGTH(2),
    TOOL_CALLS(3),
    CANCELLED(4),
    ERROR(5),
    UNKNOWN(Int.MIN_VALUE);

    public companion object {
        internal fun fromInt(v: Int): FinishReason =
            values().firstOrNull { it.nativeValue == v } ?: UNKNOWN

        internal fun fromString(s: String?): FinishReason = when (s) {
            null, "" -> NONE
            "none" -> NONE
            "stop" -> STOP
            "length" -> LENGTH
            "tool_calls" -> TOOL_CALLS
            "cancelled" -> CANCELLED
            "error" -> ERROR
            else -> UNKNOWN
        }
    }
}
