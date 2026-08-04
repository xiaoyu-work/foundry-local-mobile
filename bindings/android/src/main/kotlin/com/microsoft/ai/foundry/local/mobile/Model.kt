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

    @Volatile
    private var cachedInfo: ModelInfo? = null

    /**
     * Full metadata for the model.
     *
     * Cached after the first read: repeated access returns the same snapshot
     * without another native round-trip and JSON decode, so treating this as
     * a cheap property is safe. Fields that reflect mutable runtime state
     * ([ModelInfo.isLoaded], [ModelInfo.isCached]) are pinned to the moment
     * the snapshot was taken — use the dedicated [isLoaded] / [isCached]
     * properties for a live read, or call [refresh] to invalidate the
     * snapshot.
     *
     * The cache is invalidated automatically after [load], [unload] and
     * [delete]. Explicit [refresh] is only needed when an out-of-band change
     * — a manual filesystem edit, another process — has made the cache
     * stale.
     */
    public val info: ModelInfo
        get() {
            requireHandle()
            return cachedInfo ?: synchronized(this) {
                cachedInfo ?: JsonCodec.decode(
                    ModelInfo.serializer(),
                    NativeBridge.modelGetInfoJson(requireHandle()),
                ).also { cachedInfo = it }
            }
        }

    /**
     * Drop cached ABI reads and force a re-decode on the next access. On
     * [Model] this clears [info]; [ModelPackage] overrides it to also clear
     * [ModelPackage.variants].
     *
     * Called automatically after [load], [unload], [delete],
     * [ModelPackage.selectVariant] and [ModelPackage.selectBestVariant]; an
     * explicit call is only useful when something outside the SDK's control
     * has invalidated the cache.
     */
    public open fun refresh() {
        cachedInfo = null
    }

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
        refresh()
    }

    /** Unload the model, releasing its memory. Active sessions are stopped first. */
    public suspend fun unload() {
        JobBridge.awaitResult { corr ->
            NativeBridge.modelUnloadAsync(requireHandle(), corr)
        }
        refresh()
    }

    /** Delete the model's files from the local cache. Unloads first if loaded. */
    public suspend fun delete() {
        JobBridge.awaitResult { corr ->
            NativeBridge.modelDeleteAsync(requireHandle(), corr)
        }
        refresh()
    }

    /** Cast to [ModelPackage] if this is a package handle; returns `null` otherwise. */
    public fun asPackage(): ModelPackage? = if (isPackage) ModelPackage(requireHandle()) else null

    /**
     * Create a chat session bound to this loaded model. The caller owns the
     * result and must [ChatSession.close] it — either explicitly, via
     * `use { }`, or via the scoped helper [withChatSession], which is the
     * shortest leak-free spelling for the one-shot case.
     */
    public fun createChatSession(options: ChatOptions = ChatOptions()): ChatSession =
        ChatSession(this, options)

    /**
     * Create a speech-to-text session bound to this loaded model. See
     * [createChatSession] for lifetime management notes; the scoped
     * one-shot helper is [withAudioSession].
     */
    public fun createAudioSession(options: AudioOptions = AudioOptions()): AudioSession =
        AudioSession(this, options)

    /**
     * Create an embedding session bound to this loaded model. See
     * [createChatSession] for lifetime management notes; the scoped
     * one-shot helper is [withEmbeddingSession].
     */
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

    @Volatile
    private var cachedVariants: PackageVariants? = null

    /**
     * Snapshot of the package's variants, scored against this device.
     *
     * Cached after the first read to avoid a JSON decode on every access.
     * The cache is invalidated automatically by [selectVariant] and
     * [selectBestVariant] because those change [PackageVariants.selectedVariantId];
     * call [refresh] for an unconditional re-read.
     *
     * `downloadSizeBytes` reflects the current cache state — shared assets
     * already on disk are excluded, so the value shrinks as the cache fills.
     */
    public val variants: PackageVariants
        get() {
            requireHandle()
            return cachedVariants ?: synchronized(this) {
                cachedVariants ?: JsonCodec.decode(
                    PackageVariants.serializer(),
                    NativeBridge.packageGetVariantsJson(requireHandle()),
                ).also { cachedVariants = it }
            }
        }

    override fun refresh() {
        super.refresh()
        cachedVariants = null
    }

    /**
     * Pin the package to a specific variant. Subsequent load calls on this
     * package handle act on it.
     */
    public fun selectVariant(variantId: String) {
        NativeBridge.packageSelectVariant(requireHandle(), variantId)
        refresh()
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
        val id = NativeBridge.packageSelectBestVariant(
            requireHandle(),
            JsonCodec.encodeVariantConstraints(constraints),
        )
        refresh()
        return id
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
