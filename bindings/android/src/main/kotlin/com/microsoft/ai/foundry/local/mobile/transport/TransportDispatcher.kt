// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.mobile.transport

import com.microsoft.ai.foundry.local.mobile.internal.NativeBridge
import com.microsoft.ai.foundry.local.mobile.internal.NativeHttpRequest
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/**
 * Bridge between the C++ trampoline in `jni_transport.cc` and whatever
 * [HttpTransport] the app installs.
 *
 * Only one transport is active at a time. Calls to [install] replace the
 * previous one; the outgoing transport gets a [HttpTransport.shutdown] call.
 *
 * The dispatchers are `@JvmStatic` so the JNI trampoline can look them up as
 * plain static methods (see `jni_common.cc` — `Cached().transport_send`).
 */
public object TransportDispatcher {

    private val current = AtomicReference<HttpTransport?>(null)

    // Reference count of live FoundryLocal instances that installed the
    // current transport. Multiple managers may share a process; the
    // transport must only be uninstalled once the last one goes away.
    private val refCount = AtomicInteger(0)

    // Anchor for the C ABI report_* calls. Hooking straight into
    // NativeBridge is fine because both are singletons.
    internal object Reporter : TransportReporter {
        override fun reportProgress(requestId: Long, completedBytes: Long, totalBytes: Long) {
            NativeBridge.transportReportProgress(requestId, completedBytes, totalBytes)
        }

        override fun reportBody(requestId: Long, data: ByteArray) {
            NativeBridge.transportReportBody(requestId, data)
        }

        override fun reportComplete(
            requestId: Long,
            statusCode: Int,
            headersJson: String?,
            errorMessage: String?,
        ) {
            NativeBridge.transportReportComplete(requestId, statusCode, headersJson, errorMessage)
        }
    }

    /**
     * Install [transport] as the process-wide default and record a ref. Safe
     * to call for the same instance from multiple FoundryLocal managers.
     */
    public fun install(transport: HttpTransport) {
        val previous = current.getAndSet(transport)
        if (previous === transport) {
            refCount.incrementAndGet()
            return
        }
        if (previous != null) {
            try { previous.shutdown() } catch (_: Throwable) {}
        }
        refCount.set(1)
        NativeBridge.installDefaultTransport()
    }

    /**
     * Drop one reference and uninstall [transport] if it was the last. Called
     * from `FoundryLocal.close()`.
     */
    public fun uninstall(transport: HttpTransport) {
        if (current.get() !== transport) return
        if (refCount.decrementAndGet() > 0) return
        if (current.compareAndSet(transport, null)) {
            try { transport.shutdown() } catch (_: Throwable) {}
            try { NativeBridge.uninstallTransport() } catch (_: Throwable) {}
        }
    }

    // ---------------------------------------------------------------------
    // JNI dispatch. Names/signatures pinned by CachedClasses in jni_common.cc.
    // ---------------------------------------------------------------------

    @JvmStatic
    public fun dispatchSend(request: NativeHttpRequest): Int {
        val transport = current.get() ?: return failNoTransport(request.requestId)
        return try {
            transport.send(request, Reporter)
        } catch (t: Throwable) {
            // Failing to accept a request is fine, but if we're going to fail
            // we must not also silently leak a `report_complete`.
            try {
                Reporter.reportComplete(request.requestId, 0, null,
                    "transport threw: ${t.javaClass.simpleName}: ${t.message}")
            } catch (_: Throwable) {}
            -1
        }
    }

    @JvmStatic
    public fun dispatchCancel(requestId: Long) {
        val transport = current.get() ?: return
        try { transport.cancel(requestId) } catch (_: Throwable) {}
    }

    private fun failNoTransport(requestId: Long): Int {
        try {
            Reporter.reportComplete(requestId, 0, null, "no HTTP transport installed")
        } catch (_: Throwable) {}
        return -1
    }
}
