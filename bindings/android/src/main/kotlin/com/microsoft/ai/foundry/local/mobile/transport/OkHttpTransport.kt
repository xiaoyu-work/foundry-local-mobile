// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.mobile.transport

import com.microsoft.ai.foundry.local.mobile.internal.NativeHttpRequest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Headers
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject

/**
 * Default [HttpTransport] backed by OkHttp.
 *
 * Behaviour:
 *
 *  * **Ranged resume.** When [NativeHttpRequest.offset] is > 0 the transport
 *    sends `Range: bytes=<offset>-`, opens the destination in append mode
 *    from that offset, and writes body bytes as they arrive. This is what
 *    lets a multi-gigabyte download survive an app restart.
 *  * **In-memory delivery.** When [NativeHttpRequest.destinationPath] is
 *    `null` the body is buffered in memory (bounded — the ABI only asks for
 *    small documents like catalog listings and manifests this way) and
 *    delivered to the core with [TransportReporter.reportBody].
 *  * **Streaming progress.** Byte counts are reported as each buffer is
 *    written, throttled to avoid firing on every 8 KB read.
 *  * **Guaranteed completion.** The `report_complete` call is issued from a
 *    `finally` block on every path — success, HTTP error, IO error, or
 *    cancellation — because the core blocks a job thread waiting for it.
 *
 * Apps that need a foreground-service-backed variant for downloads that must
 * outlive backgrounding should use [WorkManagerTransport] instead, or wrap
 * this class inside a foreground service.
 */
public class OkHttpTransport(
    /**
     * The OkHttp client the transport uses. Consumers that want certificate
     * pinning, an interceptor for a custom auth scheme, or a proxy should
     * pass a pre-configured client here.
     */
    private val client: OkHttpClient = defaultClient(),
    /**
     * Cap for in-memory bodies. Prevents an accidental catalog full of GBs
     * from blowing up the heap. Applies only when `destinationPath == null`.
     */
    private val inMemoryLimitBytes: Long = 64L * 1024L * 1024L,
) : HttpTransport {

    private val calls = ConcurrentHashMap<Long, Call>()

    override fun send(request: NativeHttpRequest, reporter: TransportReporter): Int {
        val okRequest = try {
            buildRequest(request)
        } catch (t: Throwable) {
            reporter.reportComplete(request.requestId, 0, null, "invalid request: ${t.message}")
            return -1
        }

        val call = client.newCall(okRequest)
        calls[request.requestId] = call

        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                calls.remove(request.requestId)
                val message = when {
                    call.isCanceled() -> "cancelled"
                    else -> e.message ?: e.javaClass.simpleName
                }
                reporter.reportComplete(request.requestId, 0, null, message)
            }

            override fun onResponse(call: Call, response: Response) {
                calls.remove(request.requestId)
                response.use { r ->
                    val headersJson = headersToJson(r.headers)
                    val code = r.code
                    if (!r.isSuccessful) {
                        // Deliver headers + code so the core can see, e.g. a
                        // 416 for an out-of-range resume request.
                        reporter.reportComplete(request.requestId, code, headersJson,
                            "http $code ${r.message}")
                        return
                    }
                    try {
                        transferBody(request, r, reporter)
                        reporter.reportComplete(request.requestId, code, headersJson, null)
                    } catch (io: IOException) {
                        reporter.reportComplete(request.requestId, code, headersJson,
                            io.message ?: io.javaClass.simpleName)
                    } catch (t: Throwable) {
                        reporter.reportComplete(request.requestId, code, headersJson,
                            "transfer failed: ${t.message}")
                    }
                }
            }
        })
        return 0
    }

    override fun cancel(requestId: Long) {
        calls[requestId]?.cancel()
    }

    override fun shutdown() {
        // Cancel outstanding requests. Their callbacks will still fire and
        // call reportComplete("cancelled").
        for (call in calls.values) {
            try { call.cancel() } catch (_: Throwable) {}
        }
    }

    // -----------------------------------------------------------------

    private fun buildRequest(request: NativeHttpRequest): Request {
        val builder = Request.Builder().url(request.url)

        when (request.method.uppercase()) {
            "HEAD" -> builder.head()
            else -> builder.get()
        }

        parseHeaders(request.headersJson).forEach { (k, v) -> builder.header(k, v) }

        if (request.offset > 0) {
            // Range: bytes=<offset>-  — resume a partial download. The server
            // may respond 206 with a full body or 200 ignoring the range; the
            // transferBody path handles both by seeking the file to `offset`.
            builder.header("Range", "bytes=${request.offset}-")
        }

        return builder.build()
    }

    private fun transferBody(
        request: NativeHttpRequest,
        response: Response,
        reporter: TransportReporter,
    ) {
        val body = response.body ?: throw IOException("empty body")
        val expectedTotal = when {
            request.expectedBytes > 0 -> request.expectedBytes
            body.contentLength() > 0 -> body.contentLength() + request.offset
            else -> -1L
        }

        val destinationPath = request.destinationPath
        if (destinationPath.isNullOrEmpty()) {
            // In-memory delivery: buffer up to the cap, then hand off.
            val bytes = body.byteStream().use { stream ->
                val buf = java.io.ByteArrayOutputStream()
                val chunk = ByteArray(8 * 1024)
                var total = 0L
                while (true) {
                    val n = stream.read(chunk)
                    if (n <= 0) break
                    total += n
                    if (total > inMemoryLimitBytes) {
                        throw IOException("in-memory response exceeds $inMemoryLimitBytes bytes")
                    }
                    buf.write(chunk, 0, n)
                    reporter.reportProgress(request.requestId, total, expectedTotal)
                }
                buf.toByteArray()
            }
            reporter.reportBody(request.requestId, bytes)
            reporter.reportProgress(request.requestId, bytes.size.toLong(), expectedTotal)
            return
        }

        val file = File(destinationPath)
        file.parentFile?.mkdirs()
        RandomAccessFile(file, "rw").use { raf ->
            // Honour resume: seek to `offset` regardless of whether the
            // server returned 206 or 200. Requesting a `Range` and getting a
            // full 200 back is legal, and truncating would corrupt the file
            // that the core already trusts up to `offset`.
            raf.seek(request.offset)
            body.byteStream().use { stream ->
                val chunk = ByteArray(64 * 1024)
                var total = request.offset
                var lastReported = total
                while (true) {
                    val n = stream.read(chunk)
                    if (n <= 0) break
                    raf.write(chunk, 0, n)
                    total += n
                    // Throttle progress reports; the core aggregates them
                    // anyway and JNI hops are not free.
                    if (total - lastReported >= 256 * 1024) {
                        reporter.reportProgress(request.requestId, total, expectedTotal)
                        lastReported = total
                    }
                }
                if (total != lastReported) {
                    reporter.reportProgress(request.requestId, total, expectedTotal)
                }
            }
        }
    }

    private fun parseHeaders(json: String?): Map<String, String> {
        if (json.isNullOrEmpty()) return emptyMap()
        return try {
            val obj = Json.parseToJsonElement(json)
            if (obj !is JsonObject) emptyMap()
            else obj.mapValues { (_, v) -> v.jsonPrimitive.content }
        } catch (_: Throwable) {
            emptyMap()
        }
    }

    private fun headersToJson(headers: Headers): String {
        return buildJsonObject {
            headers.names().forEach { name ->
                // OkHttp folds multi-value headers into a comma-joined string.
                headers.values(name).let { values ->
                    val joined = values.joinToString(", ")
                    put(name, JsonPrimitive(joined))
                }
            }
        }.toString()
    }

    public companion object {
        /**
         * OkHttp client tuned for model downloads. Long read timeouts because
         * a slow mobile network can stall for a while without the transfer
         * having failed. Redirects enabled so signed CDN URLs work.
         */
        @JvmStatic
        public fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(30, TimeUnit.SECONDS)
            // No read timeout: some CDNs pause between chunks for tens of
            // seconds, and the core has its own stall detection.
            .readTimeout(0, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            .callTimeout(0, TimeUnit.SECONDS)
            .followRedirects(true)
            .followSslRedirects(true)
            .retryOnConnectionFailure(true)
            .build()
    }
}
