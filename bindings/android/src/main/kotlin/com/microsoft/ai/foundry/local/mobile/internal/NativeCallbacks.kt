// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.mobile.internal

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * Routes native progress / delta / completion callbacks to per-job Kotlin sinks.
 *
 * The JNI trampolines fire these dispatch* methods on a JVM-attached core
 * thread — never a UI thread, never a coroutine dispatcher. The listener
 * implementation is responsible for hopping onto the appropriate scope.
 *
 * Every registered listener is looked up by a **correlation id**, a Kotlin-side
 * counter that we pass down as the `user_data` for each async ABI call. The
 * native handle would work too, but native handles can be recycled after
 * `flm_job_release`, and correlation ids are process-unique.
 */
internal object NativeCallbacks {

    /**
     * Sink for a single job. All three methods are optional; a chat completion
     * with no delta consumer still gets [onCompletion].
     */
    internal interface Listener {
        /** Return `true` to request cancellation. */
        fun onProgress(progress: NativeProgress): Boolean = false

        /** Return `true` to request cancellation. */
        fun onDelta(delta: NativeDelta): Boolean = false

        /** Fires exactly once. */
        fun onCompletion(status: Int, errorJson: String?)
    }

    private val counter = AtomicLong(1)
    private val listeners = ConcurrentHashMap<Long, Listener>()

    /**
     * Reserve a correlation id and record the listener. The caller is expected
     * to pass the returned id into the async ABI call as the user_data.
     */
    fun register(listener: Listener): Long {
        val id = counter.getAndIncrement()
        listeners[id] = listener
        return id
    }

    /** Detach a listener without waiting for a completion callback. */
    fun unregister(correlationId: Long) {
        listeners.remove(correlationId)
    }

    // ---------------------------------------------------------------------
    // JNI entry points. These names are hard-coded into the C++ trampolines
    // via GetStaticMethodID; renaming any of them must also update the C++.
    // ---------------------------------------------------------------------

    @JvmStatic
    public fun dispatchProgress(correlationId: Long, progress: NativeProgress): Int {
        val l = listeners[correlationId] ?: return 0
        return if (l.onProgress(progress)) 1 else 0
    }

    @JvmStatic
    public fun dispatchDelta(correlationId: Long, delta: NativeDelta): Int {
        val l = listeners[correlationId] ?: return 0
        return if (l.onDelta(delta)) 1 else 0
    }

    @JvmStatic
    public fun dispatchCompletion(correlationId: Long, status: Int, errorJson: String?) {
        // Remove first, so a listener that re-enters cannot fire twice on a
        // race. The ABI guarantees single-shot completion, but we defend in
        // depth.
        val l = listeners.remove(correlationId) ?: return
        l.onCompletion(status, errorJson)
    }
}
