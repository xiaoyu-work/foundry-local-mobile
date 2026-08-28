// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.mobile

import android.content.Context
import com.microsoft.ai.foundry.local.mobile.internal.JobBridge
import com.microsoft.ai.foundry.local.mobile.internal.JsonCodec
import com.microsoft.ai.foundry.local.mobile.internal.NativeBridge
import com.microsoft.ai.foundry.local.mobile.lifecycle.LifecycleBridge
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Entry point for the Foundry Local Mobile SDK on Android.
 *
 * Create one per process; instances are internally reference-counted and can
 * be shared across activities. All expensive work happens on the core's own
 * job pool — the methods on this class either return immediately or `suspend`.
 *
 * ```kotlin
 * // create is a suspend fun; call from a coroutine scope
 * // (lifecycleScope, viewModelScope, or your own).
 * val foundry = FoundryLocal.create(context, FoundryLocalConfig(appName = "my-app"))
 *
 * // Load a model directly from a local directory path.
 * val model = foundry.loadModel(
 *     path = "/data/models/qwen2.5-0.5b",
 * ) { println("${it.percent}%") }
 *
 * val chat = model.createChatSession()
 * chat.completeStreaming("Explain the golden ratio.").collect { print(it.text) }
 * ```
 *
 * Instances hold native resources and implement [AutoCloseable]. `close()`
 * calls `flm_manager_shutdown` and then `flm_manager_release`. A finalizer is
 * present as a safety net but must not be relied on: the JVM makes no
 * guarantees about when it runs.
 */
public class FoundryLocal internal constructor(
    private val handle: Long,
    private val lifecycle: LifecycleBridge?,
) : AutoCloseable {

    private val closed = AtomicBoolean(false)

    /** ABI status codes and the message associated with the last error on this thread. */
    public val version: String get() = NativeBridge.versionString()

    /** Runtime version, or `null` if the ONNX Runtime GenAI runtime is not present. */
    public val runtimeVersion: String? get() = NativeBridge.runtimeVersionString()

    /** `true` if the underlying ONNX Runtime GenAI runtime is present and loadable. */
    public val isRuntimeAvailable: Boolean get() = NativeBridge.isRuntimeAvailable()

    /** Snapshot of the device profile the core built for model placement. */
    public val deviceProfile: DeviceProfile
        get() = JsonCodec.decode(
            DeviceProfile.serializer(),
            NativeBridge.managerGetDeviceProfileJson(requireHandle()),
        )

    /**
     * Load a model directly from a local directory path and return a ready-to-use
     * [Model].
     *
     * ```kotlin
     * val model = foundry.loadModel(
     *     path = "/data/models/phi-4-mini",
     *     executionProvider = "QNNExecutionProvider",
     * )
     * val chat = model.createChatSession()
     * ```
     *
     * @param path Absolute filesystem path to the model directory.
     * @param executionProvider Optional execution provider override.
     * @param providerOptions Optional key-value EP configuration forwarded as
     *   `provider_options` to the OGA session.
     * @param onProgress Optional progress callback for the load phase.
     * @return A loaded [Model] ready for session creation.
     * @throws FoundryLocalException if the path is invalid or loading fails.
     */
    public suspend fun loadModel(
        path: String,
        executionProvider: String? = null,
        providerOptions: Map<String, String>? = null,
        onProgress: ((Progress) -> Unit)? = null,
    ): Model {
        val options = JsonCodec.encodeLoadModelOptions(executionProvider, providerOptions)
        val result = JobBridge.awaitResult(onProgress = onProgress) { corr ->
            NativeBridge.managerLoadModelAsync(requireHandle(), path, options, corr)
        }
        return JsonCodec.parseLoadedModel(result, path)
    }

    /**
     * Update settings that can change at runtime. Mirrors
     * `flm_manager_update_settings`.
     */
    public fun updateSettings(config: FoundryLocalConfig) {
        NativeBridge.managerUpdateSettings(requireHandle(), JsonCodec.encodeUpdateSettings(config))
    }

    /** Change the SDK-wide log level. */
    public fun setLogLevel(level: LogLevel) {
        NativeBridge.setLogLevel(level.nativeValue)
    }

    /** Notify the core of an OS lifecycle transition. Called automatically by [LifecycleBridge]. */
    internal fun notifyLifecycle(event: Int) {
        if (closed.get()) return
        NativeBridge.managerNotifyLifecycle(handle, event)
    }

    /**
     * Shut down the manager and release all native resources. Idempotent; safe
     * to call from any thread. After this returns, every derived object
     * (model, session, job) is invalidated.
     */
    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        try {
            lifecycle?.detach(this)
        } catch (_: Throwable) {}
        try {
            NativeBridge.managerShutdown(handle)
        } catch (_: Throwable) {}
        try {
            NativeBridge.managerRelease(handle)
        } catch (_: Throwable) {}
    }

    @Suppress("removal", "deprecation")
    protected fun finalize() {
        // Last-resort safety net. Apps must call close() explicitly.
        if (!closed.get()) close()
    }

    internal fun requireHandle(): Long {
        check(!closed.get()) { "FoundryLocal has been closed" }
        return handle
    }

    public companion object {
        /**
         * Create the SDK using the app's private data directory.
         *
         * This function is `suspend` because it does filesystem work — it
         * creates the optional app-data directory away from the main thread.
         *
         * Call from a coroutine scope — `lifecycleScope`, `viewModelScope`,
         * or your own. Java callers can bridge via `BuildersKt.runBlocking`
         * or the standard Kotlin coroutines Java bridging APIs.
         */
        @JvmStatic
        public suspend fun create(
            context: Context,
            config: FoundryLocalConfig,
        ): FoundryLocal = withContext(Dispatchers.IO) {
            val appContext = context.applicationContext ?: context
            val filesDir = appContext.filesDir
            val dataDir = config.appDataDir ?: File(filesDir, "foundry").apply { mkdirs() }.absolutePath
            val resolved = config.copy(appDataDir = dataDir)

            val handle = NativeBridge.managerCreate(JsonCodec.encodeConfig(resolved))
            val lifecycle = LifecycleBridge.forContext(appContext)
            val instance = FoundryLocal(handle, lifecycle)
            lifecycle?.attach(instance)
            instance
        }
    }
}
