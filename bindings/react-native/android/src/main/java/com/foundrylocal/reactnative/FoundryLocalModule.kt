// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.foundrylocal.reactnative

import android.util.Base64
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.annotations.ReactModule
import com.microsoft.ai.foundry.local.mobile.AudioOptions
import com.microsoft.ai.foundry.local.mobile.AudioSession
import com.microsoft.ai.foundry.local.mobile.Catalog
import com.microsoft.ai.foundry.local.mobile.CatalogFilter
import com.microsoft.ai.foundry.local.mobile.ChatMessage
import com.microsoft.ai.foundry.local.mobile.ChatOptions
import com.microsoft.ai.foundry.local.mobile.ChatRequest
import com.microsoft.ai.foundry.local.mobile.ChatSession
import com.microsoft.ai.foundry.local.mobile.Delta
import com.microsoft.ai.foundry.local.mobile.DeviceProfile
import com.microsoft.ai.foundry.local.mobile.DownloadEstimate
import com.microsoft.ai.foundry.local.mobile.EmbeddingOptions
import com.microsoft.ai.foundry.local.mobile.EmbeddingSession
import com.microsoft.ai.foundry.local.mobile.FinishReason
import com.microsoft.ai.foundry.local.mobile.FlmDevice
import com.microsoft.ai.foundry.local.mobile.FoundryLocal
import com.microsoft.ai.foundry.local.mobile.FoundryLocalConfig
import com.microsoft.ai.foundry.local.mobile.FoundryLocalException
import com.microsoft.ai.foundry.local.mobile.LogLevel
import com.microsoft.ai.foundry.local.mobile.Model
import com.microsoft.ai.foundry.local.mobile.ModelInfo
import com.microsoft.ai.foundry.local.mobile.ModelPackage
import com.microsoft.ai.foundry.local.mobile.ModelSource
import com.microsoft.ai.foundry.local.mobile.PackageVariants
import com.microsoft.ai.foundry.local.mobile.Session
import com.microsoft.ai.foundry.local.mobile.Tool
import com.microsoft.ai.foundry.local.mobile.ToolResult
import com.microsoft.ai.foundry.local.mobile.TranscribeRequest
import com.microsoft.ai.foundry.local.mobile.VariantConstraints
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.onCompletion
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.floatOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.util.concurrent.ConcurrentHashMap

/**
 * TurboModule facade for the React Native binding.
 *
 * Design intent: keep this class thin. It accepts and returns JSON strings so
 * the codegen'd spec stays small, and delegates every real operation to the
 * Kotlin binding at `com.microsoft.ai.foundry.local.mobile.*`. As a result
 * the module has to keep track of only three things:
 *
 * 1. Slot-id maps for the four handle families (manager, catalog, model,
 *    session), so JS-visible numeric handles route back to their Kotlin
 *    objects.
 *
 * 2. A supervised coroutine scope for the `suspend` and streaming calls the
 *    JS side turns into TurboModule promises and event streams.
 *
 * 3. A subscription table mapping JS-supplied `subscriptionId`s to the
 *    `Job` collecting the underlying `Flow`, so `cancelSubscription` from
 *    JS translates into `job.cancel()` (which the Kotlin binding wires
 *    through to `flm_job_cancel`).
 *
 * Threading:
 * - TurboModule promise methods are entered on the RN native-modules
 *   thread. The underlying binding does the heavy lifting off-thread inside
 *   the C ABI's job pool, so the module only launches coroutines on
 *   [Dispatchers.Default] rather than blocking the caller.
 * - Streaming events are emitted through the standard `DeviceEventEmitter`
 *   which handles the JS-thread hop.
 * - `invalidate` runs when RN tears down the module (Reload, app exit) and
 *   drops every native handle in the reverse order they were created.
 */
@ReactModule(name = FoundryLocalModule.NAME)
class FoundryLocalModule(private val reactContext: ReactApplicationContext) :
    NativeFoundryLocalSpec(reactContext) {

    companion object {
        const val NAME = "RNFoundryLocal"

        private val JSON = Json { ignoreUnknownKeys = true; isLenient = true }

        /** `Number.MAX_SAFE_INTEGER`: the largest integer a JS double holds exactly. */
        private const val MAX_SAFE_INTEGER = 9007199254740991L
    }

    private val managers = HandleRegistry<FoundryLocal>()
    private val catalogs = HandleRegistry<Catalog>()
    private val models = HandleRegistry<Model>()
    private val sessions = HandleRegistry<Session>()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val subscriptions = ConcurrentHashMap<String, Job>()

    override fun getName(): String = NAME

    override fun invalidate() {
        subscriptions.values.forEach { it.cancel() }
        subscriptions.clear()
        sessions.releaseAll().forEach { runCatching { it.close() } }
        models.releaseAll().forEach { runCatching { it.close() } }
        catalogs.releaseAll() // borrowed from FoundryLocal; do not close
        managers.releaseAll().forEach { runCatching { it.close() } }
        scope.cancel()
        super.invalidate()
    }

    // -------------------------------------------------------------------------
    // Manager
    // -------------------------------------------------------------------------

    override fun managerCreate(configJson: String, promise: Promise) {
        launchPromise(promise) {
            val config = decodeConfig(configJson)
            val instance = FoundryLocal.create(reactContext, config)
            managers.register(instance).toDouble()
        }
    }

    override fun managerShutdown(managerId: Double, promise: Promise) {
        launchPromise(promise) {
            managers.get(managerId.toInt())?.close()
            null
        }
    }

    override fun managerRelease(managerId: Double) {
        managers.release(managerId.toInt())?.close()
    }

    override fun managerUpdateSettings(managerId: Double, configJson: String) {
        managers.require(managerId.toInt(), "Manager").updateSettings(decodeConfig(configJson))
    }

    override fun managerGetDeviceProfile(managerId: Double): String {
        val profile = managers.require(managerId.toInt(), "Manager").deviceProfile
        return JSON.encodeToString(DeviceProfile.serializer(), profile)
    }

    override fun managerGetCatalog(managerId: Double): Double {
        val catalog = managers.require(managerId.toInt(), "Manager").catalog
        return catalogs.register(catalog).toDouble()
    }

    // -------------------------------------------------------------------------
    // Manager-instance runtime probes (Kotlin binding exposes these on the
    // instance; the RN TS layer routes them through the active manager).
    // -------------------------------------------------------------------------

    override fun managerVersion(managerId: Double): String =
        managers.require(managerId.toInt(), "Manager").version

    override fun managerRuntimeVersion(managerId: Double): String =
        managers.require(managerId.toInt(), "Manager").runtimeVersion ?: ""

    override fun managerIsRuntimeAvailable(managerId: Double): Boolean =
        managers.require(managerId.toInt(), "Manager").isRuntimeAvailable

    override fun managerSetLogLevel(managerId: Double, level: Double) {
        managers.require(managerId.toInt(), "Manager").setLogLevel(logLevelFromInt(level.toInt()))
    }

    // -------------------------------------------------------------------------
    // Add model source
    // -------------------------------------------------------------------------

    override fun addModelSource(
        managerId: Double,
        sourceJson: String,
        subscriptionId: String,
        promise: Promise,
    ) {
        val instance = managers.require(managerId.toInt(), "Manager")
        val source = decodeSource(sourceJson)
        val job = scope.launch {
            try {
                val result = instance.addModelSource(source) { progress ->
                    reactContext.emit(EventNames.PROGRESS, EventPayloads.progress(subscriptionId, progress))
                }
                val modelId = result.model?.let { models.register(it) } ?: 0
                val json = buildJsonObject {
                    put("name", result.name)
                    put("path", result.path)
                    put("variant_id", result.variantId ?: "")
                    put("bytes_downloaded", result.bytesDownloaded)
                    put("bytes_reused", result.bytesReused)
                    put("was_cached", result.wasCached)
                    put("model_handle", modelId)
                    result.handleUnavailableReason?.let { put("model_handle_unavailable", it) }
                }.toString()
                subscriptions.remove(subscriptionId)
                promise.resolve(json)
            } catch (ce: CancellationException) {
                subscriptions.remove(subscriptionId)
                rejectFromCancellation(promise, ce)
            } catch (t: Throwable) {
                subscriptions.remove(subscriptionId)
                rejectFromThrowable(promise, t)
            }
        }
        subscriptions[subscriptionId] = job
    }

    // -------------------------------------------------------------------------
    // Catalog
    // -------------------------------------------------------------------------

    override fun catalogListModels(catalogId: Double, filterJson: String?, promise: Promise) {
        val catalog = catalogs.require(catalogId.toInt(), "Catalog")
        launchPromise(promise) {
            val filter = filterJson?.let { decodeCatalogFilter(it) }
            encodeModelList(catalog.listModels(filter))
        }
    }

    override fun catalogListCachedModels(catalogId: Double): String {
        val catalog = catalogs.require(catalogId.toInt(), "Catalog")
        return encodeModelList(catalog.listCachedModels())
    }

    override fun catalogGetModel(catalogId: Double, alias: String, promise: Promise) {
        val catalog = catalogs.require(catalogId.toInt(), "Catalog")
        launchPromise(promise) { models.register(catalog.getModel(alias)).toDouble() }
    }

    override fun catalogGetModelById(catalogId: Double, modelId: String, promise: Promise) {
        val catalog = catalogs.require(catalogId.toInt(), "Catalog")
        launchPromise(promise) { models.register(catalog.getModelById(modelId)).toDouble() }
    }

    override fun catalogGetCacheSizeBytes(catalogId: Double): Double {
        val catalog = catalogs.require(catalogId.toInt(), "Catalog")
        return catalog.cacheSizeBytes.toDouble()
    }

    private fun encodeModelList(list: List<ModelInfo>): String =
        buildJsonObject {
            put(
                "models",
                JSON.encodeToJsonElement(ListSerializer(ModelInfo.serializer()), list),
            )
        }.toString()

    // -------------------------------------------------------------------------
    // Model
    // -------------------------------------------------------------------------

    override fun modelGetInfo(modelId: Double): String =
        JSON.encodeToString(ModelInfo.serializer(), models.require(modelId.toInt(), "Model").info)

    override fun modelIsPackage(modelId: Double): Boolean =
        models.require(modelId.toInt(), "Model").isPackage

    override fun modelIsCached(modelId: Double): Boolean =
        models.require(modelId.toInt(), "Model").isCached

    override fun modelIsLoaded(modelId: Double): Boolean =
        models.require(modelId.toInt(), "Model").isLoaded

    override fun modelGetPath(modelId: Double): String =
        models.require(modelId.toInt(), "Model").path ?: ""

    override fun modelLoad(
        modelId: Double,
        optionsJson: String?,
        subscriptionId: String,
        promise: Promise,
    ) {
        val model = models.require(modelId.toInt(), "Model")
        val (ep, device) = decodeLoadOptions(optionsJson)
        val job = scope.launch {
            try {
                model.load(ep, device) { progress ->
                    reactContext.emit(EventNames.PROGRESS, EventPayloads.progress(subscriptionId, progress))
                }
                subscriptions.remove(subscriptionId)
                promise.resolve(null)
            } catch (ce: CancellationException) {
                subscriptions.remove(subscriptionId)
                rejectFromCancellation(promise, ce)
            } catch (t: Throwable) {
                subscriptions.remove(subscriptionId)
                rejectFromThrowable(promise, t)
            }
        }
        subscriptions[subscriptionId] = job
    }

    override fun modelUnload(modelId: Double, promise: Promise) {
        val model = models.require(modelId.toInt(), "Model")
        launchPromise(promise) { model.unload(); null }
    }

    override fun modelDelete(modelId: Double, promise: Promise) {
        val model = models.require(modelId.toInt(), "Model")
        launchPromise(promise) { model.delete(); null }
    }

    override fun modelRelease(modelId: Double) {
        models.release(modelId.toInt())?.close()
    }

    // -------------------------------------------------------------------------
    // Package
    // -------------------------------------------------------------------------

    override fun packageGetVariants(modelId: Double): String =
        JSON.encodeToString(PackageVariants.serializer(), requirePackage(modelId.toInt()).variants)

    override fun packageSelectVariant(modelId: Double, variantId: String) {
        requirePackage(modelId.toInt()).selectVariant(variantId)
    }

    override fun packageSelectBestVariant(modelId: Double, constraintsJson: String?): String {
        val constraints = constraintsJson?.let { decodeVariantConstraints(it) }
        return requirePackage(modelId.toInt()).selectBestVariant(constraints)
    }

    override fun packageGetVariant(modelId: Double, variantId: String): Double {
        val model = requirePackage(modelId.toInt()).variant(variantId)
        return models.register(model).toDouble()
    }

    override fun packageEstimateDownload(modelId: Double, variantIdsJson: String?): String {
        val ids = variantIdsJson?.let { raw ->
            (runCatching { JSON.parseToJsonElement(raw) }.getOrNull() as? JsonArray)
                ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
        }
        val estimate = requirePackage(modelId.toInt()).estimateDownload(ids)
        return JSON.encodeToString(DownloadEstimate.serializer(), estimate)
    }

    private fun requirePackage(modelId: Int): ModelPackage =
        (models.require(modelId, "Model") as? ModelPackage)
            ?: throw IllegalStateException("Model $modelId is not a package")

    // -------------------------------------------------------------------------
    // Sessions
    // -------------------------------------------------------------------------

    override fun sessionCreate(modelId: Double, optionsJson: String): Double {
        val model = models.require(modelId.toInt(), "Model")
        val root = JSON.parseToJsonElement(optionsJson).jsonObject
        val type = root["type"]?.jsonPrimitive?.contentOrNull ?: "chat"
        val session: Session = when (type) {
            "chat" -> model.createChatSession(decodeChatOptions(root))
            "audio" -> model.createAudioSession(decodeAudioOptions(root))
            "embedding" -> model.createEmbeddingSession(EmbeddingOptions())
            else -> throw IllegalArgumentException("Unknown session type '$type'")
        }
        return sessions.register(session).toDouble()
    }

    override fun sessionRelease(sessionId: Double) {
        sessions.release(sessionId.toInt())?.close()
    }

    override fun sessionSetOptions(sessionId: Double, optionsJson: String) {
        val session = sessions.require(sessionId.toInt(), "Session")
        val root = JSON.parseToJsonElement(optionsJson).jsonObject
        when (session) {
            is ChatSession -> session.updateOptions(decodeChatOptions(root))
            else -> throw UnsupportedOperationException("setOptions is only supported on ChatSession")
        }
    }

    override fun sessionExportHistory(sessionId: Double): String =
        sessions.require(sessionId.toInt(), "Session").exportHistory()

    override fun sessionRestoreHistory(sessionId: Double, historyJson: String) {
        sessions.require(sessionId.toInt(), "Session").restoreHistory(historyJson)
    }

    override fun sessionClearHistory(sessionId: Double) {
        sessions.require(sessionId.toInt(), "Session").clearHistory()
    }

    override fun sessionUndoTurns(sessionId: Double, count: Double) {
        sessions.require(sessionId.toInt(), "Session").undoTurns(count.toLong())
    }

    override fun sessionGetTurnCount(sessionId: Double): Double =
        sessions.require(sessionId.toInt(), "Session").turnCount.toDouble()

    override fun sessionComplete(sessionId: Double, requestJson: String, promise: Promise) {
        val chat = sessions.require(sessionId.toInt(), "Session") as? ChatSession
            ?: return promise.reject(errorCode(4), "Session is not a chat session")
        val request = decodeChatRequest(requestJson)
        launchPromise(promise) {
            val result = chat.complete(request)
            // Prefer the ABI's raw JSON so the TS side sees the exact wire
            // shape the core emitted (absent tool_calls vs. empty, etc.);
            // fall back to a minimal object if the binding did not preserve
            // it.
            result.rawJson ?: buildJsonObject {
                put("text", result.text)
                put("finish_reason", finishReasonToString(result.finishReason))
            }.toString()
        }
    }

    override fun sessionCompleteStreaming(
        sessionId: Double,
        requestJson: String,
        subscriptionId: String,
        promise: Promise,
    ) {
        val chat = sessions.require(sessionId.toInt(), "Session") as? ChatSession
            ?: return promise.reject(errorCode(4), "Session is not a chat session")
        streamDeltas(subscriptionId, promise) {
            chat.completeAllDeltas(decodeChatRequest(requestJson))
        }
    }

    override fun sessionSubmitToolResultsStreaming(
        sessionId: Double,
        resultsJson: String,
        subscriptionId: String,
        promise: Promise,
    ) {
        val chat = sessions.require(sessionId.toInt(), "Session") as? ChatSession
            ?: return promise.reject(errorCode(4), "Session is not a chat session")
        val results = decodeToolResults(resultsJson)
        streamDeltas(subscriptionId, promise) { chat.submitToolResults(results) }
    }

    override fun sessionTranscribe(sessionId: Double, requestJson: String, promise: Promise) {
        val audio = sessions.require(sessionId.toInt(), "Session") as? AudioSession
            ?: return promise.reject(errorCode(4), "Session is not an audio session")
        launchPromise(promise) {
            val result = audio.transcribe(decodeTranscribeRequest(requestJson))
            buildJsonObject {
                put("text", result.text)
                if (result.language != null) put("language", result.language)
                put("segments", buildJsonArray {
                    result.segments.forEach { seg ->
                        add(buildJsonObject {
                            put("text", seg.text)
                            put("start_time_ms", seg.startTimeMs)
                            put("end_time_ms", seg.endTimeMs)
                            if (seg.language != null) put("language", seg.language)
                        })
                    }
                })
            }.toString()
        }
    }

    override fun sessionTranscribeStreaming(
        sessionId: Double,
        requestJson: String,
        subscriptionId: String,
        promise: Promise,
    ) {
        val audio = sessions.require(sessionId.toInt(), "Session") as? AudioSession
            ?: return promise.reject(errorCode(4), "Session is not an audio session")
        streamDeltas(subscriptionId, promise) {
            audio.transcribeStreaming(decodeTranscribeRequest(requestJson))
        }
    }

    override fun sessionPushAudio(
        sessionId: Double,
        pcmBase64: String,
        sampleRate: Double,
        channels: Double,
        isFinal: Boolean,
    ) {
        val audio = sessions.require(sessionId.toInt(), "Session") as? AudioSession
            ?: throw IllegalStateException("Session is not an audio session")
        val bytes = Base64.decode(pcmBase64, Base64.NO_WRAP)
        audio.pushAudio(bytes, sampleRate.toInt(), channels.toInt(), isFinal)
    }

    override fun sessionEmbed(sessionId: Double, requestJson: String, promise: Promise) {
        val embed = sessions.require(sessionId.toInt(), "Session") as? EmbeddingSession
            ?: return promise.reject(errorCode(4), "Session is not an embedding session")
        val root = JSON.parseToJsonElement(requestJson).jsonObject
        val inputs = (root["inputs"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
            ?: emptyList()
        launchPromise(promise) {
            val result = embed.embed(inputs)
            buildJsonObject {
                put("dimensions", result.dimensions)
                put("embeddings", buildJsonArray {
                    result.embeddings.forEach { row ->
                        add(buildJsonArray { row.forEach { add(JsonPrimitive(it)) } })
                    }
                })
            }.toString()
        }
    }

    // -------------------------------------------------------------------------
    // Subscription lifecycle + RN emitter contract
    // -------------------------------------------------------------------------

    override fun cancelSubscription(subscriptionId: String) {
        subscriptions.remove(subscriptionId)?.cancel()
    }

    // NativeEventEmitter requires these on every module that emits events;
    // there is no per-listener work to do, so they are intentionally no-ops.
    override fun addListener(eventName: String) {}
    override fun removeListeners(count: Double) {}

    // -------------------------------------------------------------------------
    // Streaming helper
    // -------------------------------------------------------------------------

    private fun streamDeltas(
        subscriptionId: String,
        promise: Promise,
        start: () -> Flow<Delta>,
    ) {
        val job = scope.launch {
            var terminalEmitted = false
            try {
                start()
                    .catch { cause ->
                        terminalEmitted = true
                        val (status, message, detail) = decodeException(cause)
                        reactContext.emit(
                            EventNames.ERROR,
                            EventPayloads.error(subscriptionId, status, message, detail),
                        )
                    }
                    .onCompletion { cause ->
                        subscriptions.remove(subscriptionId)
                        if (!terminalEmitted) {
                            if (cause is CancellationException) {
                                reactContext.emit(
                                    EventNames.ERROR,
                                    EventPayloads.error(subscriptionId, 7, "cancelled", null),
                                )
                            } else if (cause == null) {
                                reactContext.emit(
                                    EventNames.END,
                                    EventPayloads.end(subscriptionId, null),
                                )
                            }
                        }
                    }
                    .collect { delta ->
                        reactContext.emit(EventNames.DELTA, EventPayloads.delta(subscriptionId, delta))
                    }
                promise.resolve(null)
            } catch (ce: CancellationException) {
                // The stream itself was cancelled — the onCompletion above
                // already emitted the terminal event. Resolve the promise
                // rather than rejecting: the JS side observes cancellation
                // through the ERROR event, not the promise.
                promise.resolve(null)
            } catch (t: Throwable) {
                rejectFromThrowable(promise, t)
            }
        }
        subscriptions[subscriptionId] = job
    }

    // -------------------------------------------------------------------------
    // Promise / error helpers
    // -------------------------------------------------------------------------

    private fun launchPromise(promise: Promise, block: suspend CoroutineScope.() -> Any?) {
        scope.launch {
            try {
                when (val result = block()) {
                    null -> promise.resolve(null)
                    is Double -> promise.resolve(result)
                    is Int -> promise.resolve(result.toDouble())
                    is Long -> promise.resolve(safeDouble(result))
                    is Boolean -> promise.resolve(result)
                    is String -> promise.resolve(result)
                    else -> promise.resolve(result.toString())
                }
            } catch (ce: CancellationException) {
                rejectFromCancellation(promise, ce)
            } catch (t: Throwable) {
                rejectFromThrowable(promise, t)
            }
        }
    }

    private fun rejectFromCancellation(promise: Promise, ce: CancellationException) {
        promise.reject(errorCode(7), ce.message ?: "cancelled")
    }

    /**
     * Convert a [Long] bound for JavaScript, refusing values the `number` type
     * cannot represent exactly.
     *
     * JavaScript numbers are IEEE-754 doubles and exact only to 2^53. An
     * `flm_handle` packs a kind tag into its high bits, so every valid one is
     * at least 2^56 — at that magnitude the gap between representable doubles
     * is 16, and a silent `toDouble()` would round the low four bits off the
     * slot index. Nothing would raise; the id would simply resolve to a
     * different slot or to none, surfacing much later as the wrong model
     * loading.
     *
     * No current call path returns a raw handle — ids crossing the bridge come
     * from [HandleRegistry] and are small sequential ints, and the other Longs
     * here are byte counts and timestamps well inside the safe range. This
     * guard exists so that if someone later adds one that does, it fails
     * immediately and says why instead of corrupting a lookup.
     */
    private fun safeDouble(value: Long): Double {
        if (value > MAX_SAFE_INTEGER || value < -MAX_SAFE_INTEGER) {
            throw IllegalStateException(
                "refusing to send $value across the React Native bridge: it exceeds " +
                    "JavaScript's exact-integer range (2^53) and would be silently rounded. " +
                    "If this is an flm_handle, register it in a HandleRegistry and send the " +
                    "slot id instead — see the Handles section of src/NativeFoundryLocal.ts.",
            )
        }
        return value.toDouble()
    }

    private fun rejectFromThrowable(promise: Promise, t: Throwable) {
        val (status, message, detail) = decodeException(t)
        val userInfo = Arguments.createMap().apply {
            putInt("status", status)
            if (detail != null) putString("detail", detail)
        }
        promise.reject(errorCode(status), message, t, userInfo)
    }

    private fun decodeException(t: Throwable): Triple<Int, String, String?> = when (t) {
        is FoundryLocalException -> Triple(t.status, t.messageOrEmpty, t.detailJson)
        else -> Triple(1, t.message ?: t::class.java.simpleName, null)
    }

    private fun errorCode(status: Int): String = when (status) {
        2 -> "invalidArgument"
        3 -> "invalidHandle"
        4 -> "invalidState"
        5 -> "notFound"
        6 -> "notImplemented"
        7 -> "cancelled"
        8 -> "network"
        9 -> "storage"
        10 -> "outOfMemory"
        11 -> "incompatible"
        12 -> "timeout"
        13 -> "unsupportedVersion"
        14 -> "memoryPressure"
        15 -> "shutdown"
        else -> "internal"
    }

    private fun finishReasonToString(r: FinishReason): String = when (r) {
        FinishReason.NONE -> "none"
        FinishReason.STOP -> "stop"
        FinishReason.LENGTH -> "length"
        FinishReason.TOOL_CALLS -> "tool_calls"
        FinishReason.CANCELLED -> "cancelled"
        FinishReason.ERROR -> "error"
        FinishReason.UNKNOWN -> "unknown"
    }

    // -------------------------------------------------------------------------
    // Decoders — JSON in from JS, typed request objects out to the Kotlin
    // binding.
    // -------------------------------------------------------------------------

    private fun decodeConfig(json: String): FoundryLocalConfig {
        val o = JSON.parseToJsonElement(json).jsonObject
        return FoundryLocalConfig(
            appName = o["app_name"]?.jsonPrimitive?.contentOrNull ?: "app",
            appDataDir = o["app_data_dir"]?.jsonPrimitive?.contentOrNull,
            modelCacheDir = o["model_cache_dir"]?.jsonPrimitive?.contentOrNull,
            logsDir = o["logs_dir"]?.jsonPrimitive?.contentOrNull,
            logLevel = logLevelFromString(o["log_level"]?.jsonPrimitive?.contentOrNull),
            catalogUrls = (o["catalog_urls"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull },
            catalogRegion = o["catalog_region"]?.jsonPrimitive?.contentOrNull,
            offline = o["offline"]?.jsonPrimitive?.booleanOrNull ?: false,
            maxConcurrentDownloads = o["max_concurrent_downloads"]?.jsonPrimitive?.intOrNull ?: 2,
            downloadOnMeteredNetwork = o["download_on_metered_network"]?.jsonPrimitive?.booleanOrNull ?: false,
            autoUnloadOnBackground = o["auto_unload_on_background"]?.jsonPrimitive?.booleanOrNull ?: true,
            jobPoolThreads = o["job_pool_threads"]?.jsonPrimitive?.intOrNull ?: 0,
            additionalOptions = (o["additional_options"] as? JsonObject)
                ?.mapValues { (_, v) -> (v as? JsonPrimitive)?.contentOrNull ?: "" }
                ?: emptyMap(),
        )
    }

    private fun logLevelFromString(s: String?): LogLevel = when (s) {
        "verbose" -> LogLevel.VERBOSE
        "debug" -> LogLevel.DEBUG
        "info" -> LogLevel.INFO
        "warning" -> LogLevel.WARNING
        "error" -> LogLevel.ERROR
        "fatal" -> LogLevel.FATAL
        "off" -> LogLevel.OFF
        else -> LogLevel.WARNING
    }

    private fun logLevelFromInt(v: Int): LogLevel =
        LogLevel.values().firstOrNull { it.nativeValue == v } ?: LogLevel.WARNING

    private fun decodeSource(json: String): ModelSource {
        val o = JSON.parseToJsonElement(json).jsonObject
        val name = o["name"]?.jsonPrimitive?.contentOrNull ?: ""
        val resume = o["resume"]?.jsonPrimitive?.booleanOrNull ?: true
        val verifyChecksums = o["verify_checksums"]?.jsonPrimitive?.booleanOrNull ?: true
        val constraints = (o["constraints"] as? JsonObject)?.let { decodeVariantConstraintsObject(it) }
        return when (o["kind"]?.jsonPrimitive?.contentOrNull) {
            "bundled" -> ModelSource.Bundled(
                name = name,
                path = o["path"]?.jsonPrimitive?.contentOrNull ?: "",
                copyIntoCache = o["copy_into_cache"]?.jsonPrimitive?.booleanOrNull ?: false,
                resume = resume,
                verifyChecksums = verifyChecksums,
                constraints = constraints,
            )
            "remote" -> ModelSource.Remote(
                name = name,
                url = o["url"]?.jsonPrimitive?.contentOrNull ?: "",
                headers = (o["headers"] as? JsonObject)
                    ?.mapValues { (_, v) -> (v as? JsonPrimitive)?.contentOrNull ?: "" }
                    ?: emptyMap(),
                resume = resume,
                verifyChecksums = verifyChecksums,
                constraints = constraints,
            )
            else -> throw IllegalArgumentException("Unknown model source kind")
        }
    }

    private fun decodeCatalogFilter(json: String): CatalogFilter {
        val o = JSON.parseToJsonElement(json).jsonObject
        return CatalogFilter(
            task = o["task"]?.jsonPrimitive?.contentOrNull,
            cachedOnly = o["cached_only"]?.jsonPrimitive?.booleanOrNull ?: false,
            loadedOnly = o["loaded_only"]?.jsonPrimitive?.booleanOrNull ?: false,
            maxSizeBytes = o["max_size_bytes"]?.jsonPrimitive?.longOrNull,
            compatibleOnly = o["compatible_only"]?.jsonPrimitive?.booleanOrNull ?: true,
        )
    }

    private fun decodeVariantConstraints(json: String): VariantConstraints =
        decodeVariantConstraintsObject(JSON.parseToJsonElement(json).jsonObject)

    private fun decodeVariantConstraintsObject(o: JsonObject): VariantConstraints {
        val devices = (o["allowed_devices"] as? JsonArray)
            ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull?.let(::deviceFromName) }
            ?.toSet()
        return VariantConstraints(
            maxDownloadBytes = o["max_download_bytes"]?.jsonPrimitive?.longOrNull,
            allowedDevices = devices,
            preferSmallest = o["prefer_smallest"]?.jsonPrimitive?.booleanOrNull ?: false,
            requireCached = o["require_cached"]?.jsonPrimitive?.booleanOrNull ?: false,
        )
    }

    private fun deviceFromName(name: String): FlmDevice? = when (name.lowercase()) {
        "cpu" -> FlmDevice.CPU
        "gpu" -> FlmDevice.GPU
        "npu" -> FlmDevice.NPU
        else -> null
    }

    private fun decodeLoadOptions(json: String?): Pair<String?, FlmDevice?> {
        if (json.isNullOrBlank()) return Pair(null, null)
        val o = JSON.parseToJsonElement(json).jsonObject
        val ep = o["execution_provider"]?.jsonPrimitive?.contentOrNull
        val device = o["device"]?.jsonPrimitive?.contentOrNull?.let(::deviceFromName)
        return Pair(ep, device)
    }

    private fun decodeChatOptions(o: JsonObject): ChatOptions = ChatOptions(
        systemPrompt = o["system_prompt"]?.jsonPrimitive?.contentOrNull,
        temperature = o["temperature"]?.jsonPrimitive?.floatOrNull,
        topP = o["top_p"]?.jsonPrimitive?.floatOrNull,
        topK = o["top_k"]?.jsonPrimitive?.intOrNull,
        maxOutputTokens = o["max_output_tokens"]?.jsonPrimitive?.intOrNull,
        seed = o["seed"]?.jsonPrimitive?.intOrNull,
        keepHistory = o["keep_history"]?.jsonPrimitive?.booleanOrNull ?: true,
    )

    private fun decodeAudioOptions(o: JsonObject): AudioOptions = AudioOptions(
        language = o["language"]?.jsonPrimitive?.contentOrNull,
        maxOutputTokens = o["max_output_tokens"]?.jsonPrimitive?.intOrNull,
    )

    private fun decodeChatRequest(json: String): ChatRequest {
        val o = JSON.parseToJsonElement(json).jsonObject
        val messages = (o["messages"] as? JsonArray).orEmpty().mapNotNull { el ->
            (el as? JsonObject)?.let { msg ->
                val role = msg["role"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null
                val content = msg["content"]
                // Multi-part content (image/audio parts) is not exercised
                // here yet; keep the surface minimal until an app needs it.
                ChatMessage(
                    role = role,
                    content = when (content) {
                        is JsonPrimitive -> content.contentOrNull ?: ""
                        else -> ""
                    },
                )
            }
        }
        val tools = (o["tools"] as? JsonArray).orEmpty().mapNotNull { el ->
            (el as? JsonObject)?.let { t ->
                Tool(
                    name = t["name"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null,
                    description = t["description"]?.jsonPrimitive?.contentOrNull ?: "",
                    parametersJson = t["parameters"]?.toString() ?: "{}",
                )
            }
        }
        return ChatRequest(
            messages = messages,
            tools = tools,
            toolChoice = o["tool_choice"]?.jsonPrimitive?.contentOrNull,
            temperature = o["temperature"]?.jsonPrimitive?.floatOrNull,
            maxOutputTokens = o["max_output_tokens"]?.jsonPrimitive?.intOrNull,
        )
    }

    private fun decodeToolResults(json: String): List<ToolResult> {
        val arr = JSON.parseToJsonElement(json) as? JsonArray ?: return emptyList()
        return arr.mapNotNull { el ->
            (el as? JsonObject)?.let { obj ->
                ToolResult(
                    callId = obj["call_id"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null,
                    resultJson = obj["result"]?.jsonPrimitive?.contentOrNull ?: "{}",
                )
            }
        }
    }

    private fun decodeTranscribeRequest(json: String): TranscribeRequest {
        val o = JSON.parseToJsonElement(json).jsonObject
        return when {
            o["streaming"]?.jsonPrimitive?.booleanOrNull == true -> TranscribeRequest.Streaming(
                language = o["language"]?.jsonPrimitive?.contentOrNull,
            )
            o["path"] != null -> TranscribeRequest.File(
                path = o["path"]?.jsonPrimitive?.contentOrNull ?: "",
                language = o["language"]?.jsonPrimitive?.contentOrNull,
                translate = o["translate"]?.jsonPrimitive?.booleanOrNull ?: false,
            )
            else -> TranscribeRequest.InMemory(
                dataBase64 = o["data_base64"]?.jsonPrimitive?.contentOrNull ?: "",
                format = o["format"]?.jsonPrimitive?.contentOrNull ?: "pcm",
                sampleRate = o["sample_rate"]?.jsonPrimitive?.intOrNull ?: 16000,
                channels = o["channels"]?.jsonPrimitive?.intOrNull ?: 1,
            )
        }
    }
}
