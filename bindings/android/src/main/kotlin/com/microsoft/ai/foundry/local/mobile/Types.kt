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
    /** Override the model cache path (`<appDataDir>/models` by default). */
    val modelCacheDir: String? = null,
    /** Override the logs directory. */
    val logsDir: String? = null,
    /** Default log level; also settable at runtime via [FoundryLocal.setLogLevel]. */
    val logLevel: LogLevel = LogLevel.WARNING,
    /** Catalog service URLs. `null` uses the Foundry Local defaults. */
    val catalogUrls: List<String>? = null,
    /** Preferred catalog region (e.g. "centralus"). */
    val catalogRegion: String? = null,
    /** Serve only from the local cache; never touch the catalog service. */
    val offline: Boolean = false,
    val maxConcurrentDownloads: Int = 2,
    val downloadOnMeteredNetwork: Boolean = false,
    val autoUnloadOnBackground: Boolean = true,
    /** 0 = derive from the number of CPU cores. */
    val jobPoolThreads: Int = 0,
    val additionalOptions: Map<String, String> = emptyMap(),
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
)

@Serializable
public data class ExecutionProviderInfo(
    val name: String,
    val device: FlmDevice,
    val available: Boolean,
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
// Model / package metadata
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
    @SerialName("is_package") val isPackage: Boolean = false,
    @SerialName("is_cached") val isCached: Boolean = false,
    @SerialName("is_loaded") val isLoaded: Boolean = false,
    @SerialName("prompt_templates") val promptTemplates: Map<String, String>? = null,
)

@Serializable
public data class PackageVariants(
    @SerialName("package_id") val packageId: String,
    @SerialName("schema_version") val schemaVersion: String,
    @SerialName("selected_variant_id") val selectedVariantId: String? = null,
    @SerialName("shared_assets_bytes") val sharedAssetsBytes: Long = 0,
    val variants: List<ModelVariant>,
)

@Serializable
public data class ModelVariant(
    val id: String,
    val component: String = "model",
    @SerialName("execution_provider") val executionProvider: String,
    val device: FlmDevice,
    @SerialName("compatibility_string") val compatibilityString: String = "",
    val platform: String = "any",
    @SerialName("download_size_bytes") val downloadSizeBytes: Long,
    @SerialName("disk_size_bytes") val diskSizeBytes: Long,
    @SerialName("shared_asset_refs") val sharedAssetRefs: List<String> = emptyList(),
    @SerialName("is_compatible") val isCompatible: Boolean,
    @SerialName("compatibility_score") val compatibilityScore: Int = 0,
    @SerialName("is_cached") val isCached: Boolean = false,
    @SerialName("incompatibility_reason") val incompatibilityReason: String? = null,
)

/**
 * Constraints for [ModelPackage.selectBestVariant]. Values map to the JSON
 * schema on `flm_package_select_best_variant`.
 */
public data class VariantConstraints(
    val maxDownloadBytes: Long? = null,
    val allowedDevices: Set<FlmDevice>? = null,
    val preferSmallest: Boolean = false,
)

@Serializable
public data class DownloadEstimate(
    @SerialName("download_bytes") val downloadBytes: Long,
    @SerialName("disk_bytes") val diskBytes: Long,
    @SerialName("already_cached_bytes") val alreadyCachedBytes: Long,
    @SerialName("available_storage_bytes") val availableStorageBytes: Long,
    @SerialName("fits_on_device") val fitsOnDevice: Boolean,
)

// -----------------------------------------------------------------------------
// Model sources
// -----------------------------------------------------------------------------

/**
 * Where a model comes from when the app supplies its own — bundled inside the
 * APK, or hosted on storage the app controls. See `docs/model-sources.md`.
 */
public sealed class ModelSource {
    /** Common name the model is registered under. */
    public abstract val name: String

    /**
     * A model already present on the device. The default is to load it in
     * place; set [copyIntoCache] when the source path is temporary.
     */
    public data class Bundled(
        override val name: String,
        val path: String,
        val copyIntoCache: Boolean = false,
    ) : ModelSource()

    /**
     * A model hosted at a URL. The document is sniffed rather than the URL —
     * both package manifests and flat file indexes are accepted.
     */
    public data class Remote(
        override val name: String,
        val url: String,
        val headers: Map<String, String> = emptyMap(),
    ) : ModelSource()
}

// -----------------------------------------------------------------------------
// Filter for [Catalog.listModels]
// -----------------------------------------------------------------------------

public data class CatalogFilter(
    val task: String? = null,
    val cachedOnly: Boolean = false,
    val loadedOnly: Boolean = false,
    val maxSizeBytes: Long? = null,
    val compatibleOnly: Boolean = true,
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
     * A complete tool call the model wants executed. Arguments are a JSON
     * object; parse them with [kotlinx.serialization.json.Json].
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
    ERROR(5);

    public companion object {
        internal fun fromInt(v: Int): FinishReason =
            values().firstOrNull { it.nativeValue == v } ?: NONE
    }
}

// -----------------------------------------------------------------------------
// Model source result
// -----------------------------------------------------------------------------

@Serializable
public data class ModelSourceResult(
    val name: String,
    val path: String,
    @SerialName("variant_id") val variantId: String? = null,
    @SerialName("bytes_downloaded") val bytesDownloaded: Long = 0,
    @SerialName("bytes_reused") val bytesReused: Long = 0,
    @SerialName("was_cached") val wasCached: Boolean = false,
)
