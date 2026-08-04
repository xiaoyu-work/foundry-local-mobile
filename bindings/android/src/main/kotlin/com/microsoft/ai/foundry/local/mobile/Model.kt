// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.mobile

import com.microsoft.ai.foundry.local.mobile.internal.JobBridge
import com.microsoft.ai.foundry.local.mobile.internal.JsonCodec
import com.microsoft.ai.foundry.local.mobile.internal.NativeBridge
import java.util.concurrent.atomic.AtomicBoolean

/**
 * A handle for one catalog model — a flat model, an ONNX Runtime package, or
 * a specific package variant. Use [isPackage] to distinguish, or upcast to
 * [ModelPackage] when you know a package is expected.
 *
 * Models are [AutoCloseable]. `close()` releases the handle but leaves the
 * on-disk files intact.
 */
public open class Model internal constructor(
    protected val handle: Long,
) : AutoCloseable {

    private val closed = AtomicBoolean(false)

    /** Full metadata for the model, freshly loaded from the ABI. */
    public val info: ModelInfo
        get() = JsonCodec.decode(ModelInfo.serializer(), NativeBridge.modelGetInfoJson(requireHandle()))

    /** Whether the model's files are fully present in the local cache. */
    public val isCached: Boolean get() = NativeBridge.modelIsCached(requireHandle())

    /** Whether the model is currently loaded into memory. */
    public val isLoaded: Boolean get() = NativeBridge.modelIsLoaded(requireHandle())

    /** Absolute on-disk path, or `null` when the model is not cached. */
    public val path: String?
        get() = NativeBridge.modelGetPath(requireHandle()).ifEmpty { null }

    /** `true` if this handle refers to a model package (as opposed to a flat model). */
    public val isPackage: Boolean get() = NativeBridge.modelIsPackage(requireHandle())

    /**
     * Load the model into memory.
     *
     * The model's files must already be on the device — obtain the model with
     * [FoundryLocal.addModelSource], which handles both the bundled and hosted
     * URL cases. `load` never fetches on demand; loading a model whose files
     * are absent throws [NotImplementedException] pointing at the source API.
     */
    public suspend fun load(
        executionProvider: String? = null,
        device: FlmDevice? = null,
        onProgress: ((Progress) -> Unit)? = null,
    ) {
        val opts = JsonCodec.encodeLoadOptions(executionProvider, device)
        JobBridge.awaitResult(onProgress = onProgress) { corr ->
            NativeBridge.modelLoadAsync(requireHandle(), opts, corr)
        }
    }

    /** Unload the model, releasing its memory. Active sessions are stopped first. */
    public suspend fun unload() {
        JobBridge.awaitResult { corr ->
            NativeBridge.modelUnloadAsync(requireHandle(), corr)
        }
    }

    /** Delete the model's files from the local cache. Unloads first if loaded. */
    public suspend fun delete() {
        JobBridge.awaitResult { corr ->
            NativeBridge.modelDeleteAsync(requireHandle(), corr)
        }
    }

    /** Cast to [ModelPackage] if this is a package handle; returns `null` otherwise. */
    public fun asPackage(): ModelPackage? = if (isPackage) ModelPackage(requireHandle()) else null

    /** Create a chat session bound to this loaded model. */
    public fun createChatSession(options: ChatOptions = ChatOptions()): ChatSession =
        ChatSession(this, options)

    /** Create a speech-to-text session bound to this loaded model. */
    public fun createAudioSession(options: AudioOptions = AudioOptions()): AudioSession =
        AudioSession(this, options)

    /** Create an embedding session bound to this loaded model. */
    public fun createEmbeddingSession(options: EmbeddingOptions = EmbeddingOptions()): EmbeddingSession =
        EmbeddingSession(this, options)

    /** Native handle for internal consumers. Do not expose. */
    internal fun nativeHandle(): Long = requireHandle()

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        try { NativeBridge.modelRelease(handle) } catch (_: Throwable) {}
    }

    @Suppress("removal", "deprecation")
    protected fun finalize() {
        if (!closed.get()) close()
    }

    protected fun requireHandle(): Long {
        check(!closed.get()) { "Model has been closed" }
        return handle
    }

    internal companion object {
        fun wrap(handle: Long): Model {
            require(handle != 0L) { "Invalid model handle" }
            return if (NativeBridge.modelIsPackage(handle)) ModelPackage(handle) else Model(handle)
        }
    }
}

/**
 * A model package handle. Extends [Model] with variant enumeration, imperative
 * selection and pre-download estimation. Instances are returned by
 * [Catalog.getModel] or [Catalog.getModelById] whenever the underlying entry
 * is a package.
 *
 * Prefer expressing variant policy declaratively on the source: pass
 * [VariantConstraints] to [ModelSource.Remote] or [ModelSource.Bundled] and
 * the SDK scores the manifest before any weights transfer. The imperative
 * methods on this class are for apps that need to inspect the manifest, run a
 * post-download re-selection, or manage multiple variants in parallel.
 */
public class ModelPackage internal constructor(handle: Long) : Model(handle) {

    /**
     * Snapshot of the package's variants, scored against this device.
     *
     * `downloadSizeBytes` reflects the current cache state — shared assets
     * already on disk are excluded, so the value shrinks as the cache fills.
     */
    public val variants: PackageVariants
        get() = JsonCodec.decode(
            PackageVariants.serializer(),
            NativeBridge.packageGetVariantsJson(requireHandle()),
        )

    /**
     * Pin the package to a specific variant. Subsequent load calls on this
     * package handle act on it.
     */
    public fun selectVariant(variantId: String) {
        NativeBridge.packageSelectVariant(requireHandle(), variantId)
    }

    /**
     * Let the SDK pick the best variant for this device using the device
     * profile, the variants' compatibility scores and any [constraints].
     * Returns the id of the winning variant.
     *
     * When a [ModelSource]'s own `constraints` were set this has already run
     * once as part of `addModelSource`; call it again only when the app needs
     * to override that decision at runtime.
     */
    public fun selectBestVariant(constraints: VariantConstraints? = null): String {
        return NativeBridge.packageSelectBestVariant(
            requireHandle(),
            JsonCodec.encodeVariantConstraints(constraints),
        )
    }

    /**
     * Obtain a standalone handle for one variant. Useful for apps that want to
     * manage several variants in parallel (e.g. an NPU variant downloading in
     * the background while a CPU variant serves requests).
     */
    public fun variant(variantId: String): Model {
        val handle = NativeBridge.packageGetVariant(requireHandle(), variantId)
        return Model.wrap(handle)
    }

    /**
     * Estimate the transfer for [variantIds] before committing. Passing `null`
     * uses the currently selected variant.
     */
    public fun estimateDownload(variantIds: Collection<String>? = null): DownloadEstimate {
        val json = NativeBridge.packageEstimateDownloadJson(
            requireHandle(),
            JsonCodec.encodeVariantIds(variantIds),
        )
        return JsonCodec.decode(DownloadEstimate.serializer(), json)
    }
}
