// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.mobile.internal

import com.microsoft.ai.foundry.local.mobile.Delta
import com.microsoft.ai.foundry.local.mobile.FoundryLocalException
import com.microsoft.ai.foundry.local.mobile.Progress
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.channels.ProducerScope
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Coroutine adapters over the native job/callback ABI.
 *
 * These helpers own the correlation-id lifecycle and the `flm_job_release`
 * call, so callers only supply the JNI call that starts a job. Cancellation of
 * the coroutine is wired through to `flm_job_cancel` — the completion callback
 * still fires once with FLM_ERROR_CANCELLED, which is how the job resources
 * are reclaimed.
 */
internal object JobBridge {

    /**
     * Wait for a job that returns a JSON result. Suspends until the completion
     * callback fires, then returns the result JSON (or `null` if none).
     *
     * @param onProgress optional; called from the JNI dispatcher on a core
     *                   thread. Must not block.
     * @param start lambda that starts the JNI call, receives the correlation
     *              id, and returns the native job handle.
     */
    suspend fun awaitResult(
        onProgress: ((Progress) -> Unit)? = null,
        start: (correlationId: Long) -> Long,
    ): String? = suspendCancellableCoroutine { cont ->
        val listener = ResultListener(cont, onProgress)
        val correlationId = NativeCallbacks.register(listener)
        val job = try {
            start(correlationId)
        } catch (t: Throwable) {
            NativeCallbacks.unregister(correlationId)
            cont.resumeWithException(t)
            return@suspendCancellableCoroutine
        }
        listener.jobHandle = job

        cont.invokeOnCancellation {
            try {
                NativeBridge.jobCancel(job)
            } catch (_: Throwable) { /* releasing an unknown handle is a no-op */ }
        }
    }

    /**
     * Stream deltas from a job that also produces a terminal result. The flow
     * completes when the ABI reports FLM_JOB_SUCCEEDED, and errors when it
     * reports any other failure state. Collecting-side cancellation propagates
     * to `flm_job_cancel`.
     */
    fun stream(
        onProgress: ((Progress) -> Unit)? = null,
        start: (correlationId: Long) -> Long,
    ): Flow<Delta> = callbackFlow {
        val listener = DeltaListener(this, onProgress)
        val correlationId = NativeCallbacks.register(listener)

        val job = try {
            start(correlationId)
        } catch (t: Throwable) {
            NativeCallbacks.unregister(correlationId)
            close(t)
            return@callbackFlow
        }
        listener.jobHandle = job

        awaitClose {
            try {
                NativeBridge.jobCancel(job)
            } catch (_: Throwable) {}
            NativeCallbacks.unregister(correlationId)
        }
    }

    /**
     * Stream progress from a long-running job. Emits [Progress] as it arrives;
     * completes with the terminal result JSON (or throws) via the companion
     * suspend variant [awaitResult].
     */
    fun progressStream(
        start: (correlationId: Long) -> Long,
    ): Flow<Progress> = callbackFlow {
        val listener = ProgressStreamListener(this)
        val correlationId = NativeCallbacks.register(listener)

        val job = try {
            start(correlationId)
        } catch (t: Throwable) {
            NativeCallbacks.unregister(correlationId)
            close(t)
            return@callbackFlow
        }
        listener.jobHandle = job

        awaitClose {
            try {
                NativeBridge.jobCancel(job)
            } catch (_: Throwable) {}
            NativeCallbacks.unregister(correlationId)
        }
    }

    // ---- Listener implementations --------------------------------------

    private class ResultListener(
        private val cont: CancellableContinuation<String?>,
        private val onProgress: ((Progress) -> Unit)?,
    ) : NativeCallbacks.Listener {
        @Volatile var jobHandle: Long = 0L

        override fun onProgress(progress: NativeProgress): Boolean {
            onProgress?.invoke(Progress.from(progress))
            return !cont.isActive
        }

        override fun onCompletion(status: Int, errorJson: String?) {
            val handle = jobHandle
            try {
                if (status == 0) {
                    val json = try {
                        if (handle != 0L) NativeBridge.jobTakeResultJson(handle) else null
                    } catch (t: Throwable) {
                        cont.resumeWithException(t)
                        return
                    }
                    cont.resume(json)
                } else {
                    cont.resumeWithException(exceptionFor(status, errorJson))
                }
            } finally {
                if (handle != 0L) {
                    try { NativeBridge.jobRelease(handle) } catch (_: Throwable) {}
                }
            }
        }
    }

    private class DeltaListener(
        private val scope: ProducerScope<Delta>,
        private val onProgress: ((Progress) -> Unit)?,
    ) : NativeCallbacks.Listener {
        @Volatile var jobHandle: Long = 0L

        override fun onProgress(progress: NativeProgress): Boolean {
            onProgress?.invoke(Progress.from(progress))
            return !scope.isActive
        }

        override fun onDelta(delta: NativeDelta): Boolean {
            val d = Delta.from(delta)
            val result = scope.trySend(d)
            return !scope.isActive || result.isFailure && !result.isClosed
        }

        override fun onCompletion(status: Int, errorJson: String?) {
            val handle = jobHandle
            try {
                if (status == 0) {
                    scope.close()
                } else {
                    scope.close(exceptionFor(status, errorJson))
                }
            } finally {
                if (handle != 0L) {
                    try { NativeBridge.jobRelease(handle) } catch (_: Throwable) {}
                }
            }
        }
    }

    private class ProgressStreamListener(
        private val scope: ProducerScope<Progress>,
    ) : NativeCallbacks.Listener {
        @Volatile var jobHandle: Long = 0L

        override fun onProgress(progress: NativeProgress): Boolean {
            val result = scope.trySend(Progress.from(progress))
            return !scope.isActive || (result.isFailure && !result.isClosed)
        }

        override fun onCompletion(status: Int, errorJson: String?) {
            val handle = jobHandle
            try {
                if (status == 0) {
                    // Emit a terminal 100% progress so collectors that only
                    // watch percent see the transition.
                    scope.trySend(Progress(100f, -1, -1, -1, -1, "completed", null))
                    scope.close()
                } else {
                    scope.close(exceptionFor(status, errorJson))
                }
            } finally {
                if (handle != 0L) {
                    try { NativeBridge.jobRelease(handle) } catch (_: Throwable) {}
                }
            }
        }
    }

    private fun exceptionFor(status: Int, errorJson: String?): FoundryLocalException {
        val message = errorJson?.let { extractMessage(it) } ?: "foundry_local status $status"
        return FoundryLocalException.fromStatus(status, message, errorJson)
    }

    private val messageRegex = Regex("\"message\"\\s*:\\s*\"([^\"]*)\"")

    private fun extractMessage(json: String): String? {
        // Cheap, allocation-light extraction that avoids pulling in kotlinx.serialization
        // in the hot callback path. If the JSON is more complex we fall back
        // to the raw string.
        return messageRegex.find(json)?.groupValues?.getOrNull(1)
    }
}
