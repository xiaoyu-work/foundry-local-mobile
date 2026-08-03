// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.mobile.transport

import com.microsoft.ai.foundry.local.mobile.internal.NativeHttpRequest

/**
 * The HTTP transport the SDK uses to fetch model manifests and weights.
 *
 * The core plans downloads but never performs them; every request the core
 * decides to make is handed to an implementation of this interface. That
 * indirection is what lets multi-gigabyte downloads survive the app being
 * backgrounded, and what makes the app's certificate pinning, proxy
 * configuration and credential refresh Just Work — because the request goes
 * through the app's own HTTP stack.
 *
 * See `docs/model-sources.md` for the full contract.
 *
 * ### Threading
 *
 * [send] is called on a core job-pool thread and **must return immediately**.
 * Start the work on an internal executor and return 0 to signal acceptance,
 * non-zero to fail fast.
 *
 * [cancel] may arrive on any thread. It must be idempotent and non-blocking.
 *
 * ### Reporting
 *
 * For every request that [send] accepts (returns 0), the transport must call
 * exactly one [TransportReporter.reportComplete] — including for cancelled
 * and failed requests. The core blocks a job-pool thread waiting for it, so
 * a missed report is a permanent hang.
 */
public interface HttpTransport {
    /**
     * Start [request]. Return 0 to indicate acceptance; the transport is then
     * responsible for completing it via [reporter]. Return non-zero to fail
     * the request immediately (no reportComplete needed).
     */
    public fun send(request: NativeHttpRequest, reporter: TransportReporter): Int

    /** Cancel a request previously accepted by [send]. */
    public fun cancel(requestId: Long)

    /**
     * Called when the SDK shuts down. Cancel outstanding work and release any
     * resources the transport holds.
     */
    public fun shutdown() {}
}

/**
 * Callback surface transports use to feed the core. Every method is safe to
 * call from any thread.
 */
public interface TransportReporter {
    /**
     * Report bytes transferred. `totalBytes` may be `-1` when the size is
     * unknown (chunked encoding, or a HEAD result that omitted it).
     */
    public fun reportProgress(requestId: Long, completedBytes: Long, totalBytes: Long)

    /**
     * Deliver body bytes for an in-memory request — one whose
     * [NativeHttpRequest.destinationPath] was `null`. Requests that name a
     * destination must write directly to that path instead; the SDK reads it
     * back from disk.
     */
    public fun reportBody(requestId: Long, data: ByteArray)

    /**
     * Report that a request finished. Must be called exactly once per
     * accepted request, including cancelled and failed ones.
     *
     * @param statusCode HTTP status (200, 206, 4xx, 5xx). Use 0 for a
     *                   transport-level failure that never reached the wire.
     * @param headersJson response headers as a JSON object; `null` if not
     *                    available.
     * @param errorMessage `null` on success; a short description otherwise.
     */
    public fun reportComplete(
        requestId: Long,
        statusCode: Int,
        headersJson: String?,
        errorMessage: String?,
    )
}
