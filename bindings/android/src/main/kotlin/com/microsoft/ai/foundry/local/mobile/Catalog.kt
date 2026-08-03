// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.mobile

import com.microsoft.ai.foundry.local.mobile.internal.JobBridge
import com.microsoft.ai.foundry.local.mobile.internal.JsonCodec
import com.microsoft.ai.foundry.local.mobile.internal.NativeBridge
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

/**
 * The catalog of models known to the SDK — remote entries advertised by the
 * Foundry Local catalog service plus anything the app has registered through
 * [FoundryLocal.addModelSource].
 *
 * Borrowed from [FoundryLocal.catalog]; do not close directly.
 */
public class Catalog internal constructor(private val handle: Long) {

    /**
     * List catalog models, optionally filtered. Serves from the network the
     * first time and from an in-memory cache thereafter.
     */
    public suspend fun listModels(filter: CatalogFilter? = null): List<ModelInfo> {
        val json = JobBridge.awaitResult { corr ->
            NativeBridge.catalogListModelsAsync(handle, JsonCodec.encodeFilter(filter), corr)
        } ?: return emptyList()

        val root = JsonCodec.parseObject(json)
        val models = root["models"] ?: return emptyList()
        return JsonCodec.lenient.decodeFromJsonElement(ListSerializer(ModelInfo.serializer()), models)
    }

    /**
     * Models present in the local cache. Synchronous and safe to call at
     * startup before any network is available.
     */
    public fun listCachedModels(): List<ModelInfo> {
        val json = NativeBridge.catalogListCachedModelsJson(handle)
        val root = JsonCodec.parseObject(json)
        val models = root["models"] ?: return emptyList()
        return JsonCodec.lenient.decodeFromJsonElement(ListSerializer(ModelInfo.serializer()), models)
    }

    /**
     * Resolve a catalog model by its short alias (e.g. `"qwen2.5-0.5b"`).
     */
    public suspend fun getModel(alias: String): Model {
        val json = JobBridge.awaitResult { corr ->
            NativeBridge.catalogGetModelAsync(handle, alias, corr)
        } ?: throw FoundryLocalException.fromStatus(
            5, "no model handle returned for alias '$alias'", null,
        )
        val modelHandle = JsonCodec.parseObject(json)["model_handle"]?.jsonPrimitive?.long
            ?: throw FoundryLocalException.fromStatus(5, "model_handle missing from catalog result", json)
        return Model.wrap(modelHandle)
    }

    /**
     * Resolve a specific variant by its fully qualified model id. This
     * bypasses automatic variant selection and is normally called only when
     * the app wants to pin a variant across upgrades.
     */
    public suspend fun getModelById(modelId: String): Model {
        val json = JobBridge.awaitResult { corr ->
            NativeBridge.catalogGetModelByIdAsync(handle, modelId, corr)
        } ?: throw FoundryLocalException.fromStatus(5, "no model handle for id '$modelId'", null)
        val modelHandle = JsonCodec.parseObject(json)["model_handle"]?.jsonPrimitive?.long
            ?: throw FoundryLocalException.fromStatus(5, "model_handle missing from catalog result", json)
        return Model.wrap(modelHandle)
    }

    /** Bytes currently consumed by the model cache. */
    public val cacheSizeBytes: Long
        get() = NativeBridge.catalogGetCacheSizeBytes(handle)
}
