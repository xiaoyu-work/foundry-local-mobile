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
 * The catalog of models known to the SDK — models the app has registered
 * through [FoundryLocal.addModelSource] plus anything the manifest server
 * advertises.
 *
 * **The catalog is for inspection, not acquisition.** Use
 * [FoundryLocal.addModelSource] to supply a model, then query the catalog to
 * enumerate what is on the device, look up metadata, or get a handle to a
 * model that was registered earlier. Downloading through the catalog is not
 * a supported flow on mobile — the Foundry Local catalog publishes desktop
 * builds that a phone cannot execute.
 *
 * Borrowed from [FoundryLocal.catalog]; do not close directly.
 */
public class Catalog internal constructor(private val handle: Long) {

    /**
     * List catalog models, optionally filtered. Reads the currently known
     * catalog — the app's own registered sources plus anything advertised by
     * a configured manifest server.
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
