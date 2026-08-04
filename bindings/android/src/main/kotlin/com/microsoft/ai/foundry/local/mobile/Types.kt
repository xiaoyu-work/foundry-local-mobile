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
) {
    /**
     * Concise human-readable summary of the ABI, core count and every
     * currently-available execution provider, e.g.
     * `arm64-v8a, 8 cores, EPs: QNN (NPU), XNNPACK (CPU)`.
     *
     * Meant for a debug log or a settings screen — every debug UI wants
     * exactly this string and every one of them was writing the join by
     * hand before this property existed. Unavailable providers are elided;
     * if none is available the summary ends with `EPs: CPU only`.
     *
     * The field is a computed property, not a serialized one — it does not
     * appear in the JSON that [DeviceProfile] is decoded from.
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
    /**
     * `true` if the provider is registered with the runtime and can be
     * selected. Providers reported by the runtime but not built or otherwise
     * disabled for this device are still listed with `available = false` so
     * a debug UI can render them.
     */
    val available: Boolean,
    /**
     * Scheduling priority the SDK uses when picking a placement for a
     * variant. **Lower wins** — the ordering encodes "fastest acceptable
     * placement first" — so `0` is the most-preferred provider and higher
     * values are progressively worse fallbacks.
     *
     * Concrete values from the platform detectors:
     * `0` for accelerator providers (QNN, NNAPI, CoreML, OpenVINO,
     * VitisAI), `10` for GPU providers (CUDA, DirectML, Metal, WebGPU,
     * ROCm), `20` for XNNPACK (the fast ARM CPU path), `30` for the generic
     * CPU provider, and `100` for providers the SDK does not otherwise
     * classify. Sort ascending in a debug UI to see the SDK's own preference
     * order.
     */
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
 * Constraints for variant selection. Applied by `flm_package_select_best_variant`
 * and, more importantly for cross-platform apps, honoured by
 * [FoundryLocal.addModelSource] when set on the [ModelSource] itself — the
 * scoring runs against the manifest before any weights transfer, so a phone
 * never spends bytes on a variant it cannot run.
 */
public data class VariantConstraints(
    /** Skip variants whose selected files exceed this many bytes. */
    val maxDownloadBytes: Long? = null,
    /**
     * Restrict placement to these devices. `null` and empty set both mean
     * "any device" — set only when the app needs to force, e.g., NPU-only.
     */
    val allowedDevices: Set<FlmDevice>? = null,
    /**
     * Break ties on download size rather than the compatibility score. Off
     * by default; the score already rewards native placements.
     */
    val preferSmallest: Boolean = false,
    /**
     * Only consider variants whose files are already on disk. Useful for an
     * offline path or a "no more downloads" preference.
     */
    val requireCached: Boolean = false,
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
     * Whether a partial download already on disk should be resumed. Defaults
     * to `true`. Set `false` to force a fresh fetch — the core discards any
     * partial file and refetches from offset 0.
     */
    public abstract val resume: Boolean

    /**
     * Whether each file's SHA-256 is verified after download and against a
     * previously downloaded copy. Defaults to `true`. Turning this off makes
     * an incremental catalog refresh cheaper on device but disables the
     * corruption check the core normally performs.
     */
    public abstract val verifyChecksums: Boolean

    /**
     * Variant selection policy applied when the source resolves to an ONNX
     * Runtime model package. The scoring runs against the manifest before any
     * weights transfer, so declaring `constraints` is the cheapest way to
     * express a cross-platform preference like "NPU if available, else CPU,
     * cap at 800 MB". Ignored for a flat model.
     */
    public abstract val constraints: VariantConstraints?

    /**
     * A model already present on the device. The default is to load it in
     * place: the cache entry links back to [path] instead of copying the
     * weights, so the app keeps owning those files and must keep them where
     * they are. Set [copyIntoCache] when it cannot promise that.
     */
    public data class Bundled(
        override val name: String,
        val path: String,
        /**
         * Copy the model into the SDK's cache instead of linking to [path].
         * Costs a second copy of the weights, and for a package only the
         * selected variant is copied. Use it when [path] is a staging
         * directory, shared storage the user can clear, or an OS cache that
         * may be reclaimed — anywhere the files could vanish under the SDK.
         */
        val copyIntoCache: Boolean = false,
        override val resume: Boolean = true,
        override val verifyChecksums: Boolean = true,
        /**
         * Variant policy for a bundled package. Applied before any files are
         * touched; a variant not permitted by [constraints] is discarded from
         * the manifest even if its files were shipped inside the APK.
         */
        override val constraints: VariantConstraints? = null,
    ) : ModelSource()

    /**
     * A model hosted at a URL. The document is sniffed rather than the URL —
     * both package manifests and flat file indexes are accepted.
     */
    public data class Remote(
        override val name: String,
        val url: String,
        val headers: Map<String, String> = emptyMap(),
        override val resume: Boolean = true,
        override val verifyChecksums: Boolean = true,
        /**
         * Variant policy applied against the manifest **before** any bytes
         * transfer. This is the cross-platform way to express "use the NPU
         * build if you can, up to 800 MB, else fall back to CPU" — the SDK
         * scores every variant and only fetches the winner plus the shared
         * assets it references.
         */
        override val constraints: VariantConstraints? = null,
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
    /**
     * Hide models this device cannot run. Defaults to `true` here, and in the
     * Swift and Dart bindings, because a mobile app almost never wants to
     * offer a model the device will refuse to load. The ABI itself treats an
     * absent `compatible_only` as `false`; the friendlier default belongs to
     * the bindings, which is why all of them send the key explicitly.
     */
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
    /**
     * The same value as [percent] expressed as a fraction in `[0f, 1f]`,
     * pre-clamped so it can be passed directly to `LinearProgressIndicator`
     * or an equivalent widget without further validation. The ABI reports
     * `0..100` and [percent] preserves that; this is a UI helper, not a
     * wire field, and is deliberately excluded from `equals`, `hashCode`,
     * `toString` and `copy`.
     */
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
     * raw JSON payload the model produced — usually a JSON object matching
     * the tool's declared schema. A runaway model may emit something that
     * does not match, and deciding what to do about that belongs to the
     * app; parse defensively.
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
    /** The runtime reported no terminal reason (still generating, or unset). */
    NONE(0),
    /** Natural end of turn or a stop sequence was hit. */
    STOP(1),
    /** Output token limit was reached. */
    LENGTH(2),
    /** The model is waiting on tool results. */
    TOOL_CALLS(3),
    /** Cancelled by the caller. */
    CANCELLED(4),
    /** Aborted by an error. */
    ERROR(5),

    /**
     * A reason the runtime returned but this binding does not model. The raw
     * value is available in [CompleteResult.rawJson]. Never thrown; the SDK
     * decodes forward-compatibly so a runtime update cannot break callers.
     */
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

// -----------------------------------------------------------------------------
// Model source result
// -----------------------------------------------------------------------------

/**
 * Outcome of a successful [FoundryLocal.addModelSource]. The model's files are
 * on disk at [path] regardless of whether [model] is populated.
 *
 * [model] is the ready-to-use handle the core minted inside the same job. It is
 * `null` in the unexpected case where the download succeeded but the catalog's
 * local scan did not pick the files up — the caller can then look the model up
 * by [name] through [FoundryLocal.catalog] or work from [path] directly. The
 * download itself succeeded either way; the null case is not an error.
 */
public data class ModelSourceResult(
    val name: String,
    val path: String,
    val variantId: String? = null,
    val bytesDownloaded: Long = 0,
    val bytesReused: Long = 0,
    val wasCached: Boolean = false,
    val model: Model? = null,
) {
    /**
     * Return [model] when the core surfaced a handle, and throw an
     * [IllegalStateException] otherwise.
     *
     * Apps that only ever add package sources — which is the common case,
     * because that is the whole point of the two-source design — should not
     * have to pay null-handling ceremony for an outcome that only arises
     * when the SDK's catalog scan misses a completed download. If it does
     * happen the throw message names both [name] and [path] so a caller
     * can look the model up by name through [FoundryLocal.catalog] or work
     * from the on-disk path directly without extra plumbing.
     *
     * Callers that want to handle the null case explicitly — falling back
     * to a catalog lookup, showing a different UI, or reporting telemetry
     * — should read [model] directly instead of calling this.
     */
    public fun requireModel(): Model = model ?: error(
        "Model source \"$name\" was added successfully — files are on disk at " +
            "\"$path\" — but the SDK's catalog scan did not surface a handle. This " +
            "is a catalog-side bug, not a download failure. Look the model up by " +
            "name through FoundryLocal.catalog or work from the path directly.",
    )
}
