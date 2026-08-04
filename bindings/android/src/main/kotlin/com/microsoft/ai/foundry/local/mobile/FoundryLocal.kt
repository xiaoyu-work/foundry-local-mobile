// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.mobile

import android.content.Context
import com.microsoft.ai.foundry.local.mobile.internal.JsonCodec
import com.microsoft.ai.foundry.local.mobile.internal.NativeBridge
import com.microsoft.ai.foundry.local.mobile.internal.JobBridge
import com.microsoft.ai.foundry.local.mobile.lifecycle.LifecycleBridge
import com.microsoft.ai.foundry.local.mobile.transport.OkHttpTransport
import com.microsoft.ai.foundry.local.mobile.transport.TransportDispatcher
import com.microsoft.ai.foundry.local.mobile.transport.HttpTransport
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
 * // Acquire a model: bundled inside the APK, or hosted at a URL the app controls.
 * // The catalog does not fetch models; addModelSource is the only supply path.
 * val result = foundry.addModelSource(
 *     ModelSource.Remote(name = "qwen2.5-0.5b", url = "https://.../manifest.json"),
 * ) { println("${it.percent}%") }
 *
 * // requireModel() throws the rare "download succeeded but catalog missed it" case
 * // with an actionable message; use `result.model ?: catalog.getModel(name)` to
 * // handle it explicitly.
 * val model = result.requireModel()
 * model.load()
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
    private val transport: HttpTransport,
    private val lifecycle: LifecycleBridge?,
) : AutoCloseable {

    private val closed = AtomicBoolean(false)

    /** ABI status codes and the message associated with the last error on this thread. */
    public val version: String get() = NativeBridge.versionString()

    /** Runtime version, or `null` if the Foundry Local runtime is not present. */
    public val runtimeVersion: String? get() = NativeBridge.runtimeVersionString()

    /** `true` if the underlying Foundry Local runtime is present and loadable. */
    public val isRuntimeAvailable: Boolean get() = NativeBridge.isRuntimeAvailable()

    /**
     * The catalog owned by this manager. Borrowed; do not release directly.
     */
    public val catalog: Catalog by lazy { Catalog(NativeBridge.managerGetCatalog(requireHandle())) }

    /**
     * Snapshot of the device profile the core built for scoring variants and
     * planning downloads.
     */
    public val deviceProfile: DeviceProfile
        get() = JsonCodec.decode(
            DeviceProfile.serializer(),
            NativeBridge.managerGetDeviceProfileJson(requireHandle()),
        )

    /**
     * Install a bundled or remote model as a first-class catalog entry.
     *
     * See `docs/model-sources.md`. When [source] is a [ModelSource.Remote] the
     * default OkHttp transport downloads only the variant this device can run
     * plus its shared assets; when it is a [ModelSource.Bundled] the files are
     * loaded in place, or copied into the cache if the app requests it.
     *
     * The result carries the resolved [ModelSourceResult.name],
     * [ModelSourceResult.path] and, in the common case, a ready-to-use
     * [ModelSourceResult.model] the core minted inside the same job. `model`
     * is `null` only when the download succeeded but the catalog's local scan
     * did not find the files afterwards; the caller can then look the model
     * up by name through [catalog] or work from [ModelSourceResult.path]
     * directly.
     *
     * Progress is optional; typical UI code uses it to show a "download in
     * progress" spinner.
     */
    public suspend fun addModelSource(
        source: ModelSource,
        onProgress: ((Progress) -> Unit)? = null,
    ): ModelSourceResult {
        val json = JsonCodec.encodeSource(source)
        val result = JobBridge.awaitResult(onProgress = onProgress) { corr ->
            NativeBridge.managerAddModelSourceAsync(requireHandle(), json, corr)
        }
        return JsonCodec.parseModelSourceResult(result, source.name)
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
     * (catalog, model, session, job) is invalidated.
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
        TransportDispatcher.uninstall(transport)
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
         * Create the SDK using the app's private data directory. The default
         * OkHttp-backed transport is installed at the same time.
         *
         * This function is `suspend` because it does filesystem work — it
         * creates the app data, model cache and log directories, and the
         * `flm_manager_create` call it invokes may kick off a catalog refresh
         * that scans a cache holding several gigabytes of model files. On the
         * main thread that is a StrictMode violation and a plausible ANR on
         * a cold start with a populated cache; the dispatch to
         * [Dispatchers.IO] below makes it structurally impossible to get
         * that wrong.
         *
         * Call from a coroutine scope — `lifecycleScope`, `viewModelScope`,
         * or your own. Java callers can bridge via `BuildersKt.runBlocking`
         * or the standard Kotlin coroutines Java bridging APIs.
         */
        @JvmStatic
        @JvmOverloads
        public suspend fun create(
            context: Context,
            config: FoundryLocalConfig,
            transport: HttpTransport = OkHttpTransport(),
        ): FoundryLocal = withContext(Dispatchers.IO) {
            val appContext = context.applicationContext ?: context
            val filesDir = appContext.filesDir
            val dataDir = config.appDataDir ?: File(filesDir, "foundry").apply { mkdirs() }.absolutePath
            val cacheDir = config.modelCacheDir ?: File(dataDir, "models").apply {
                mkdirs()
            }.absolutePath
            val logsDir = config.logsDir ?: File(dataDir, "logs").apply { mkdirs() }.absolutePath

            val resolved = config.copy(
                appDataDir = dataDir,
                modelCacheDir = cacheDir,
                logsDir = logsDir,
            )

            // Install the transport before creating the manager, because the
            // manager may kick off a catalog refresh from its constructor.
            TransportDispatcher.install(transport)

            val handle = try {
                NativeBridge.managerCreate(JsonCodec.encodeConfig(resolved))
            } catch (t: Throwable) {
                TransportDispatcher.uninstall(transport)
                throw t
            }

            val lifecycle = LifecycleBridge.forContext(appContext)
            val instance = FoundryLocal(handle, transport, lifecycle)
            lifecycle?.attach(instance)
            instance
        }
    }
}
