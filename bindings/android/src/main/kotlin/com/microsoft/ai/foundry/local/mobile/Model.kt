// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.mobile

import com.microsoft.ai.foundry.local.mobile.internal.JobBridge
import com.microsoft.ai.foundry.local.mobile.internal.JsonCodec
import com.microsoft.ai.foundry.local.mobile.internal.NativeBridge
import java.util.concurrent.atomic.AtomicBoolean

/**
 * A handle for one model.
 *
 * Models are [AutoCloseable]. `close()` releases the handle but leaves the
 * on-disk files intact.
 */
public class Model internal constructor(
    private val handle: Long,
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
     * The cache is invalidated automatically after [load] and [unload].
     * Explicit [refresh] is only needed when an out-of-band change — a manual
     * filesystem edit, another process — has made the cache stale.
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
     * Drop cached ABI reads and force a re-decode on the next access.
     *
     * Called automatically after [load] and [unload]; an explicit call is only
     * useful when something outside the SDK's control has invalidated the cache.
     */
    public fun refresh() {
        cachedInfo = null
    }

    /** Whether the model's files are fully present in the local cache. */
    public val isCached: Boolean get() = NativeBridge.modelIsCached(requireHandle())

    /** Whether the model is currently loaded into memory. */
    public val isLoaded: Boolean get() = NativeBridge.modelIsLoaded(requireHandle())

    /** Absolute on-disk path, or `null` when the model is not cached. */
    public val path: String?
        get() = NativeBridge.modelGetPath(requireHandle()).ifEmpty { null }

    /**
     * Load the model into memory.
     *
     * The model's files must already be on the device. `load` never fetches on
     * demand; it only maps an existing model into memory.
     */
    public suspend fun load(
        executionProvider: String? = null,
        providerOptions: Map<String, String>? = null,
        device: FlmDevice? = null,
        onProgress: ((Progress) -> Unit)? = null,
    ) {
        val opts = JsonCodec.encodeLoadOptions(executionProvider, providerOptions, device)
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
     * [createChatSession] for lifetime management notes; the scoped one-shot
     * helper is [withAudioSession].
     */
    public fun createAudioSession(options: AudioOptions = AudioOptions()): AudioSession =
        AudioSession(this, options)

    /**
     * Create an embedding session bound to this loaded model. See
     * [createChatSession] for lifetime management notes; the scoped one-shot
     * helper is [withEmbeddingSession].
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

    private fun requireHandle(): Long {
        check(!closed.get()) { "Model has been closed" }
        return handle
    }

    internal companion object {
        fun wrap(handle: Long): Model {
            require(handle != 0L) { "Invalid model handle" }
            return Model(handle)
        }
    }
}
