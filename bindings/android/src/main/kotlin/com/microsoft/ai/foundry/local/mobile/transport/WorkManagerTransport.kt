// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.mobile.transport

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.microsoft.ai.foundry.local.mobile.internal.NativeHttpRequest
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentHashMap

/**
 * Transport that hands each download request off to Android's WorkManager, so
 * a multi-gigabyte transfer keeps running when the app is backgrounded.
 *
 * Trade-off vs. [OkHttpTransport]:
 *
 *  * WorkManager scheduling adds seconds of latency before a request starts
 *    running — cheap for a 3 GB download, unacceptable for a HEAD to sniff a
 *    manifest.
 *  * WorkManager's own network constraints can defer a job until the device
 *    is on unmetered Wi-Fi, which is usually what the user wants.
 *
 * So this transport uses OkHttp for small in-memory requests (catalog
 * listings, manifest sniffs) and WorkManager for anything that streams to
 * disk. The `destinationPath` is the only signal we need to tell them apart.
 *
 * To use it, replace the default in [com.microsoft.ai.foundry.local.mobile.FoundryLocal.create]:
 *
 * ```kotlin
 * FoundryLocal.create(context, cfg, transport = WorkManagerTransport(context))
 * ```
 *
 * WorkManager requires an application context, so this transport captures
 * `context.applicationContext` from its constructor.
 */
public class WorkManagerTransport(
    context: Context,
    /**
     * Client used for lightweight in-memory requests. Pass a shared instance
     * if the app already keeps one around.
     */
    private val inline: OkHttpTransport = OkHttpTransport(),
    /**
     * When set, WorkManager jobs are constrained to this network type.
     * Defaults to CONNECTED (any network) so the manager-level metered policy
     * still governs the actual behaviour.
     */
    private val requiredNetworkType: NetworkType = NetworkType.CONNECTED,
    /**
     * Whether WorkManager requires the device to be charging. Off by
     * default; the SDK is a foreground feature and defers to app policy.
     */
    private val requiresCharging: Boolean = false,
) : HttpTransport {

    private val appContext = context.applicationContext ?: context

    override fun send(request: NativeHttpRequest, reporter: TransportReporter): Int {
        // Small responses that live in memory go straight through OkHttp; the
        // WorkManager overhead only pays for itself on large disk transfers.
        if (request.destinationPath.isNullOrEmpty()) {
            return inline.send(request, reporter)
        }

        val id = request.requestId
        pending[id] = ReporterBinding(reporter, CompletableDeferred())

        val data = workDataOf(
            KEY_REQUEST_ID to id,
            KEY_URL to request.url,
            KEY_METHOD to request.method,
            KEY_HEADERS_JSON to request.headersJson,
            KEY_DESTINATION to request.destinationPath,
            KEY_OFFSET to request.offset,
            KEY_EXPECTED_BYTES to request.expectedBytes,
        )

        val constraints = Constraints.Builder()
            .setRequiredNetworkType(requiredNetworkType)
            .setRequiresCharging(requiresCharging)
            .build()

        val work = OneTimeWorkRequestBuilder<DownloadWorker>()
            .setInputData(data)
            .setConstraints(constraints)
            .addTag(workTag(id))
            .build()

        WorkManager.getInstance(appContext).enqueueUniqueWork(
            uniqueName(id),
            ExistingWorkPolicy.REPLACE,
            work,
        )
        return 0
    }

    override fun cancel(requestId: Long) {
        WorkManager.getInstance(appContext).cancelAllWorkByTag(workTag(requestId))
        // In case the request is still small-path, forward the cancel there.
        inline.cancel(requestId)
    }

    override fun shutdown() {
        inline.shutdown()
    }

    // -----------------------------------------------------------------

    internal companion object {
        internal const val KEY_REQUEST_ID = "flm.requestId"
        internal const val KEY_URL = "flm.url"
        internal const val KEY_METHOD = "flm.method"
        internal const val KEY_HEADERS_JSON = "flm.headersJson"
        internal const val KEY_DESTINATION = "flm.dest"
        internal const val KEY_OFFSET = "flm.offset"
        internal const val KEY_EXPECTED_BYTES = "flm.expected"

        internal val pending: ConcurrentHashMap<Long, ReporterBinding> = ConcurrentHashMap()

        internal fun workTag(id: Long): String = "flm-download-$id"
        internal fun uniqueName(id: Long): String = "flm-download-$id"
    }

    internal data class ReporterBinding(
        val reporter: TransportReporter,
        val doneSignal: CompletableDeferred<Unit>,
    )
}

/**
 * The [CoroutineWorker] WorkManager runs. It re-runs the OkHttp transport
 * from within the worker's coroutine scope, forwarding progress and completion
 * to the [TransportReporter] the app registered when the request was enqueued.
 *
 * A worker without a matching pending reporter (which can happen if the SDK
 * was reinitialised between enqueue and worker start) still calls the OkHttp
 * transport; it just discards the results — safer than leaving a stale file
 * half-written.
 */
public class DownloadWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val id = inputData.getLong(WorkManagerTransport.KEY_REQUEST_ID, 0L)
        if (id == 0L) return@withContext Result.failure()

        val request = NativeHttpRequest(
            requestId = id,
            url = inputData.getString(WorkManagerTransport.KEY_URL) ?: return@withContext Result.failure(),
            method = inputData.getString(WorkManagerTransport.KEY_METHOD) ?: "GET",
            headersJson = inputData.getString(WorkManagerTransport.KEY_HEADERS_JSON) ?: "{}",
            destinationPath = inputData.getString(WorkManagerTransport.KEY_DESTINATION),
            offset = inputData.getLong(WorkManagerTransport.KEY_OFFSET, 0L),
            expectedBytes = inputData.getLong(WorkManagerTransport.KEY_EXPECTED_BYTES, -1L),
        )

        val binding = WorkManagerTransport.pending[id]
        val reporter = binding?.reporter ?: DiscardingReporter

        val transport = OkHttpTransport()
        val done = CompletableDeferred<Unit>()

        val forwarded = object : TransportReporter {
            override fun reportProgress(requestId: Long, completedBytes: Long, totalBytes: Long) {
                reporter.reportProgress(requestId, completedBytes, totalBytes)
                if (totalBytes > 0) {
                    val percent = (completedBytes * 100 / totalBytes).toInt()
                    setProgressAsync(Data.Builder().putInt("percent", percent).build())
                }
            }
            override fun reportBody(requestId: Long, data: ByteArray) {
                reporter.reportBody(requestId, data)
            }
            override fun reportComplete(
                requestId: Long, statusCode: Int, headersJson: String?, errorMessage: String?,
            ) {
                try {
                    reporter.reportComplete(requestId, statusCode, headersJson, errorMessage)
                } finally {
                    binding?.doneSignal?.complete(Unit)
                    done.complete(Unit)
                }
            }
        }

        val startResult = transport.send(request, forwarded)
        if (startResult != 0) {
            return@withContext Result.failure()
        }
        // Await completion so WorkManager keeps the process alive for the
        // whole transfer.
        done.await()
        WorkManagerTransport.pending.remove(id)
        Result.success()
    }
}

private object DiscardingReporter : TransportReporter {
    override fun reportProgress(requestId: Long, completedBytes: Long, totalBytes: Long) {}
    override fun reportBody(requestId: Long, data: ByteArray) {}
    override fun reportComplete(
        requestId: Long, statusCode: Int, headersJson: String?, errorMessage: String?,
    ) {}
}
