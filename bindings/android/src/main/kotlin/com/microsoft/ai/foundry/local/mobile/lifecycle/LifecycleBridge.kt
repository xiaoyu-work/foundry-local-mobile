// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.mobile.lifecycle

import android.content.ComponentCallbacks2
import android.content.Context
import android.content.res.Configuration
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import com.microsoft.ai.foundry.local.mobile.FoundryLocal
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Wires OS lifecycle and memory-pressure notifications into
 * `flm_manager_notify_lifecycle`.
 *
 * The core needs foreground/background transitions to auto-unload models
 * before iOS jetsam or Android low-memory kills the process. It needs memory
 * warnings to trim caches.
 *
 * There is one bridge instance per process, and it multiplexes into every
 * live [FoundryLocal]. Registration is idempotent: if this class is not
 * initialised through the manifest [LifecycleInitializer], calling
 * [attach] on the first [FoundryLocal.create] will lazily initialise it.
 */
public class LifecycleBridge private constructor(private val appContext: Context) :
    DefaultLifecycleObserver, ComponentCallbacks2 {

    private val instances = CopyOnWriteArraySet<FoundryLocal>()
    private val started = AtomicBoolean(false)

    /** Register [instance] to receive lifecycle callbacks. */
    public fun attach(instance: FoundryLocal) {
        instances.add(instance)
        ensureStarted()
    }

    /** Detach [instance]. Called from [FoundryLocal.close]. */
    public fun detach(instance: FoundryLocal) {
        instances.remove(instance)
    }

    private fun ensureStarted() {
        if (!started.compareAndSet(false, true)) return
        try {
            ProcessLifecycleOwner.get().lifecycle.addObserver(this)
        } catch (_: Throwable) {
            // ProcessLifecycleOwner is only meaningful for apps, not e.g.
            // instrumented tests running without the initializer. Fall
            // through to the ComponentCallbacks2 path, which still works.
        }
        appContext.registerComponentCallbacks(this)
    }

    // ---------------------------------------------------------------
    // Lifecycle
    // ---------------------------------------------------------------

    override fun onStart(owner: LifecycleOwner) {
        broadcast(FLM_LIFECYCLE_FOREGROUND)
    }

    override fun onStop(owner: LifecycleOwner) {
        broadcast(FLM_LIFECYCLE_BACKGROUND)
    }

    // ---------------------------------------------------------------
    // Memory
    // ---------------------------------------------------------------

    override fun onTrimMemory(level: Int) {
        // The Android trim levels don't line up with the core's two-tier
        // signal cleanly; we treat anything RUNNING_LOW or below as a warning
        // and BACKGROUND-level or worse as critical, matching the guidance in
        // ComponentCallbacks2.TRIM_MEMORY_*.
        val event = when {
            level >= ComponentCallbacks2.TRIM_MEMORY_COMPLETE -> FLM_LIFECYCLE_MEMORY_CRITICAL
            level >= ComponentCallbacks2.TRIM_MEMORY_MODERATE -> FLM_LIFECYCLE_MEMORY_WARNING
            level >= ComponentCallbacks2.TRIM_MEMORY_BACKGROUND -> FLM_LIFECYCLE_MEMORY_WARNING
            level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL -> FLM_LIFECYCLE_MEMORY_CRITICAL
            level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW -> FLM_LIFECYCLE_MEMORY_WARNING
            else -> return
        }
        broadcast(event)
    }

    @Deprecated("required by ComponentCallbacks2 but replaced by onTrimMemory")
    override fun onLowMemory() {
        broadcast(FLM_LIFECYCLE_MEMORY_WARNING)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {}

    private fun broadcast(event: Int) {
        for (i in instances) {
            try { i.notifyLifecycle(event) } catch (_: Throwable) {}
        }
    }

    public companion object {
        // Mirrors flm_lifecycle_event in flm_types.h.
        internal const val FLM_LIFECYCLE_FOREGROUND = 0
        internal const val FLM_LIFECYCLE_BACKGROUND = 1
        internal const val FLM_LIFECYCLE_MEMORY_WARNING = 2
        internal const val FLM_LIFECYCLE_MEMORY_CRITICAL = 3
        internal const val FLM_LIFECYCLE_LOW_POWER = 4
        internal const val FLM_LIFECYCLE_THERMAL_THROTTLING = 5

        @Volatile private var singleton: LifecycleBridge? = null

        /**
         * The singleton for this process. Null-safe when neither the
         * initializer nor an explicit [FoundryLocal.create] has run yet.
         */
        @JvmStatic
        public fun forContext(context: Context): LifecycleBridge? {
            val appContext = context.applicationContext ?: return null
            val existing = singleton
            if (existing != null) return existing
            synchronized(this) {
                val second = singleton
                if (second != null) return second
                val bridge = LifecycleBridge(appContext)
                singleton = bridge
                return bridge
            }
        }
    }
}
