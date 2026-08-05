// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.mobile.internal

import com.microsoft.ai.foundry.local.mobile.CatalogFilter
import com.microsoft.ai.foundry.local.mobile.FlmDevice
import com.microsoft.ai.foundry.local.mobile.FoundryLocalConfig
import com.microsoft.ai.foundry.local.mobile.Model
import com.microsoft.ai.foundry.local.mobile.ModelSource
import com.microsoft.ai.foundry.local.mobile.ModelSourceResult
import com.microsoft.ai.foundry.local.mobile.VariantConstraints
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/**
 * Encoders / decoders that live between the strongly typed Kotlin data classes
 * and the loosely typed JSON the C ABI speaks. Kept internal so the wire
 * format is not part of the public API.
 */
internal object JsonCodec {

    val lenient: Json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
        encodeDefaults = false
    }

    fun encodeConfig(config: FoundryLocalConfig): String = buildJsonObject {
        put("app_name", config.appName)
        config.appDataDir?.let { put("app_data_dir", it) }
        config.modelCacheDir?.let { put("model_cache_dir", it) }
        config.logsDir?.let { put("logs_dir", it) }
        put("log_level", config.logLevel.name.lowercase())
        config.catalogUrls?.let {
            put("catalog_urls", buildJsonArray { it.forEach { url -> add(url) } })
        }
        config.catalogRegion?.let { put("catalog_region", it) }
        put("offline", config.offline)
        put("max_concurrent_downloads", config.maxConcurrentDownloads)
        put("download_on_metered_network", config.downloadOnMeteredNetwork)
        put("auto_unload_on_background", config.autoUnloadOnBackground)
        put("job_pool_threads", config.jobPoolThreads)
        if (config.additionalOptions.isNotEmpty()) {
            put("additional_options", buildJsonObject {
                config.additionalOptions.forEach { (k, v) -> put(k, v) }
            })
        }
    }.toString()

    fun encodeUpdateSettings(config: FoundryLocalConfig): String = buildJsonObject {
        put("log_level", config.logLevel.name.lowercase())
        put("offline", config.offline)
        put("max_concurrent_downloads", config.maxConcurrentDownloads)
        put("download_on_metered_network", config.downloadOnMeteredNetwork)
        put("auto_unload_on_background", config.autoUnloadOnBackground)
    }.toString()

    fun encodeSource(source: ModelSource): String = when (source) {
        is ModelSource.Bundled -> buildJsonObject {
            put("kind", "bundled")
            put("name", source.name)
            put("path", source.path)
            put("copy_into_cache", source.copyIntoCache)
            put("resume", source.resume)
            put("verify_checksums", source.verifyChecksums)
            source.constraints?.let { put("constraints", constraintsElement(it)) }
        }.toString()
        is ModelSource.Remote -> buildJsonObject {
            put("kind", "remote")
            put("name", source.name)
            put("url", source.url)
            if (source.headers.isNotEmpty()) {
                put("headers", buildJsonObject {
                    source.headers.forEach { (k, v) -> put(k, v) }
                })
            }
            put("resume", source.resume)
            put("verify_checksums", source.verifyChecksums)
            source.constraints?.let { put("constraints", constraintsElement(it)) }
        }.toString()
    }

    fun encodeFilter(filter: CatalogFilter?): String? {
        if (filter == null) return null
        return buildJsonObject {
            filter.task?.let { put("task", it) }
            put("cached_only", filter.cachedOnly)
            put("loaded_only", filter.loadedOnly)
            filter.maxSizeBytes?.let { put("max_size_bytes", it) }
            put("compatible_only", filter.compatibleOnly)
        }.toString()
    }

    fun encodeVariantConstraints(constraints: VariantConstraints?): String? {
        if (constraints == null) return null
        return constraintsElement(constraints).toString()
    }

    private fun constraintsElement(constraints: VariantConstraints): JsonObject = buildJsonObject {
        constraints.maxDownloadBytes?.let { put("max_download_bytes", it) }
        constraints.allowedDevices?.let {
            put("allowed_devices", buildJsonArray {
                it.forEach { d -> add(deviceName(d)) }
            })
        }
        put("prefer_smallest", constraints.preferSmallest)
        put("require_cached", constraints.requireCached)
    }

    fun encodeLoadOptions(executionProvider: String?, device: FlmDevice?): String? {
        if (executionProvider == null && device == null) return null
        return buildJsonObject {
            executionProvider?.let { put("execution_provider", it) }
            device?.let { put("device", deviceName(it)) }
        }.toString()
    }

    fun encodeVariantIds(ids: Collection<String>?): String? =
        if (ids == null) null
        else buildJsonArray { ids.forEach { add(it) } }.toString()

    fun <T> decode(deserializer: kotlinx.serialization.DeserializationStrategy<T>, json: String): T =
        lenient.decodeFromString(deserializer, json)

    fun parseObject(json: String): JsonObject = lenient.parseToJsonElement(json).let {
        it as? JsonObject ?: throw IllegalArgumentException("Expected JSON object, got $it")
    }

    fun parseElement(json: String): JsonElement = lenient.parseToJsonElement(json)

    fun parseModelSourceResult(json: String?, fallbackName: String): ModelSourceResult {
        val obj = if (json.isNullOrBlank()) JsonObject(emptyMap()) else parseObject(json)
        val name = obj["name"]?.jsonPrimitive?.contentOrNull ?: fallbackName
        val path = obj["path"]?.jsonPrimitive?.contentOrNull.orEmpty()
        val variantId = obj["variant_id"]?.jsonPrimitive?.contentOrNull?.ifEmpty { null }
        val bytesDownloaded = obj["bytes_downloaded"]?.jsonPrimitive?.longOrNull ?: 0L
        val bytesReused = obj["bytes_reused"]?.jsonPrimitive?.longOrNull ?: 0L
        val wasCached = obj["was_cached"]?.jsonPrimitive?.booleanOrNull ?: false
        // model_handle is a flm_handle (uint64). Signed Long is a safe carrier
        // for every practical value the core mints; 0 means no handle, and the
        // core says why alongside it. Not a failure — the files are installed.
        val handle = obj["model_handle"]?.jsonPrimitive?.longOrNull ?: 0L
        val model = if (handle != 0L) Model.wrap(handle) else null
        return ModelSourceResult(
            name = name,
            path = path,
            variantId = variantId,
            bytesDownloaded = bytesDownloaded,
            bytesReused = bytesReused,
            wasCached = wasCached,
            model = model,
            handleUnavailableReason =
                obj["model_handle_unavailable"]?.jsonPrimitive?.contentOrNull?.ifEmpty { null },
        )
    }

    private fun deviceName(device: FlmDevice): String = when (device) {
        FlmDevice.CPU -> "cpu"
        FlmDevice.GPU -> "gpu"
        FlmDevice.NPU -> "npu"
        FlmDevice.UNKNOWN -> "unknown"
    }
}
