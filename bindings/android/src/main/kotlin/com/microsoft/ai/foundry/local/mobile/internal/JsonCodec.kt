// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.mobile.internal

import com.microsoft.ai.foundry.local.mobile.FlmDevice
import com.microsoft.ai.foundry.local.mobile.FoundryLocalConfig
import com.microsoft.ai.foundry.local.mobile.FoundryLocalException
import com.microsoft.ai.foundry.local.mobile.Model
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
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
        put("log_level", config.logLevel.name.lowercase())
        put("auto_unload_on_background", config.autoUnloadOnBackground)
        put("job_pool_threads", config.jobPoolThreads)
    }.toString()

    fun encodeUpdateSettings(config: FoundryLocalConfig): String = buildJsonObject {
        put("log_level", config.logLevel.name.lowercase())
        put("auto_unload_on_background", config.autoUnloadOnBackground)
    }.toString()

    fun encodeLoadOptions(executionProvider: String?, providerOptions: Map<String, String>?, device: FlmDevice?): String? {
        if (executionProvider == null && providerOptions == null && device == null) return null
        return buildJsonObject {
            executionProvider?.let { put("execution_provider", it) }
            providerOptions?.let { opts ->
                if (opts.isNotEmpty()) {
                    put("provider_options", buildJsonObject {
                        opts.forEach { (k, v) -> put(k, v) }
                    })
                }
            }
            device?.let { put("device", deviceName(it)) }
        }.toString()
    }

    fun encodeLoadModelOptions(executionProvider: String?, providerOptions: Map<String, String>?): String? =
        encodeLoadOptions(executionProvider, providerOptions, device = null)

    fun <T> decode(deserializer: kotlinx.serialization.DeserializationStrategy<T>, json: String): T =
        lenient.decodeFromString(deserializer, json)

    fun parseObject(json: String): JsonObject = lenient.parseToJsonElement(json).let {
        it as? JsonObject ?: throw IllegalArgumentException("Expected JSON object, got $it")
    }

    fun parseElement(json: String): JsonElement = lenient.parseToJsonElement(json)

    fun parseLoadedModel(json: String?, path: String): Model {
        val obj = if (json.isNullOrBlank()) JsonObject(emptyMap()) else parseObject(json)
        val handle = obj["model_handle"]?.jsonPrimitive?.longOrNull ?: 0L
        if (handle == 0L) {
            throw FoundryLocalException.fromStatus(3, "No model handle returned for path '$path'.", json)
        }
        return Model.wrap(handle)
    }

    private fun deviceName(device: FlmDevice): String = when (device) {
        FlmDevice.CPU -> "cpu"
        FlmDevice.GPU -> "gpu"
        FlmDevice.NPU -> "npu"
        FlmDevice.UNKNOWN -> "unknown"
    }
}
