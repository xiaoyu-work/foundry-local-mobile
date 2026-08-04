// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.mobile

import com.microsoft.ai.foundry.local.mobile.internal.JobBridge
import com.microsoft.ai.foundry.local.mobile.internal.JsonCodec
import com.microsoft.ai.foundry.local.mobile.internal.NativeBridge
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Common base for all inference sessions.
 *
 * A session owns a KV cache and a small amount of runtime state on top of the
 * loaded model. Release with [close] when done; leaving a session alive
 * indefinitely holds memory that a background trim would otherwise reclaim.
 */
public abstract class Session internal constructor(
    protected val model: Model,
    protected val handle: Long,
) : AutoCloseable {

    private val closed = AtomicBoolean(false)

    /**
     * Update mutable session settings. Same schema as the session's
     * constructor options.
     */
    protected fun setNativeOptions(optionsJson: String) {
        NativeBridge.sessionSetOptions(requireHandle(), optionsJson)
    }

    /** Number of completed turns in the conversation. */
    public val turnCount: Long get() = NativeBridge.sessionGetTurnCount(requireHandle())

    /** Drop the last [count] turns. */
    public fun undoTurns(count: Long) {
        NativeBridge.sessionUndoTurns(requireHandle(), count)
    }

    /** Discard all conversation history, keeping the session and its options. */
    public fun clearHistory() {
        NativeBridge.sessionClearHistory(requireHandle())
    }

    /**
     * Serialize the session so it can be restored after the process is
     * killed. Returns the JSON payload.
     */
    public fun exportHistory(): String = NativeBridge.sessionExportHistoryJson(requireHandle())

    /** Restore history previously produced by [exportHistory]. */
    public fun restoreHistory(historyJson: String) {
        NativeBridge.sessionRestoreHistoryJson(requireHandle(), historyJson)
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        try { NativeBridge.sessionRelease(handle) } catch (_: Throwable) {}
    }

    @Suppress("removal", "deprecation")
    protected fun finalize() {
        if (!closed.get()) close()
    }

    protected fun requireHandle(): Long {
        check(!closed.get()) { "Session has been closed" }
        return handle
    }
}

// -----------------------------------------------------------------------------
// Chat
// -----------------------------------------------------------------------------

public class ChatSession internal constructor(model: Model, options: ChatOptions) :
    Session(model, createNative(model, options)) {

    /** Update the session's chat options. */
    public fun updateOptions(options: ChatOptions) {
        setNativeOptions(encodeOptions("chat", options))
    }

    /**
     * Run a chat completion in streaming mode. The [prompt] is added as a
     * single user turn to the session history.
     *
     * Emits **only** text fragments — tool calls, usage accounting and the
     * completion event are dropped. That matches what a chat UI typically
     * wants; a caller that needs those events (a tool-calling agent, a
     * token-cost meter, a UI that lights up on `FinishReason.LENGTH`) must
     * build a [ChatRequest] and use [completeAllDeltas] instead.
     */
    public fun completeStreaming(prompt: String): Flow<Delta.Text> = completeStreaming(userTurn(prompt))

    /**
     * Streaming completion with a raw OpenAI-shaped [ChatRequest].
     *
     * Emits **only** text fragments — tool calls, usage accounting and the
     * completion event are dropped. See [completeAllDeltas] for the
     * everything-flavoured overload, and see [complete] for a non-streaming
     * variant that returns tool calls and usage on a single result object.
     */
    public fun completeStreaming(request: ChatRequest): Flow<Delta.Text> =
        JobBridge.stream { corr ->
            NativeBridge.sessionCompleteAsync(requireHandle(), request.toJson(), true, corr)
        }.mapNotNull { it as? Delta.Text }

    /**
     * Streaming completion emitting **every** delta kind — text fragments,
     * reasoning fragments, tool calls, usage accounting and the terminal
     * `Delta.Completed`.
     *
     * Reach for this when the app needs tool call events or per-turn token
     * counts. Chat UIs that only need to paint text into a bubble should
     * prefer [completeStreaming], whose narrower return type
     * ([kotlinx.coroutines.flow.Flow] of [Delta.Text]) is easier to consume
     * — the type says "you get text or nothing", so callers do not have to
     * `is` check every element.
     */
    public fun completeAllDeltas(request: ChatRequest): Flow<Delta> =
        JobBridge.stream { corr ->
            NativeBridge.sessionCompleteAsync(requireHandle(), request.toJson(), true, corr)
        }

    /** Non-streaming completion. Returns the whole assistant text. */
    public suspend fun complete(prompt: String): CompleteResult = complete(userTurn(prompt))

    public suspend fun complete(request: ChatRequest): CompleteResult {
        val json = JobBridge.awaitResult { corr ->
            NativeBridge.sessionCompleteAsync(requireHandle(), request.toJson(), false, corr)
        } ?: return CompleteResult(text = "", finishReason = FinishReason.NONE)
        val obj = JsonCodec.parseObject(json)
        val text = obj["text"]?.jsonPrimitive?.content ?: ""
        val finishReason = FinishReason.fromString(obj["finish_reason"]?.jsonPrimitive?.content)
        // The ABI treats absent-vs-empty for `tool_calls` and `usage` as
        // meaningful: absent = the runtime had nothing to report, empty =
        // could not happen because the empty case is reported as absent.
        // Preserve the distinction by using null for "absent" instead of
        // collapsing to an empty list.
        val toolCalls = (obj["tool_calls"] as? JsonArray)?.mapNotNull { el ->
            (el as? JsonObject)?.let { tc ->
                Delta.ToolCall(
                    callId = tc["call_id"]?.jsonPrimitive?.content ?: return@mapNotNull null,
                    name = tc["name"]?.jsonPrimitive?.content ?: return@mapNotNull null,
                    // Wire form: arguments is a JSON *string* (double-encoded)
                    // because the model may emit something that does not match
                    // the tool schema, and it's the app's job to decide.
                    argumentsJson = tc["arguments"]?.jsonPrimitive?.content ?: "{}",
                )
            }
        }
        val usage = (obj["usage"] as? JsonObject)?.let { u ->
            Delta.Usage(
                promptTokens = u["prompt_tokens"]?.jsonPrimitive?.content?.toLongOrNull() ?: 0L,
                completionTokens = u["completion_tokens"]?.jsonPrimitive?.content?.toLongOrNull() ?: 0L,
            )
        }
        return CompleteResult(text, finishReason, toolCalls, usage, json)
    }

    /**
     * Continue a turn by delivering results for tools the model asked to call.
     * [results] pairs each `call_id` with the JSON-encoded return value.
     */
    public fun submitToolResults(results: List<ToolResult>): Flow<Delta> {
        val payload = buildJsonArray {
            results.forEach { r ->
                addJsonObject {
                    put("call_id", r.callId)
                    // The ABI takes `result` as a stringified JSON, so we pass
                    // the caller's raw JSON string through unchanged.
                    put("result", r.resultJson)
                }
            }
        }.toString()
        return JobBridge.stream { corr ->
            NativeBridge.sessionSubmitToolResultsAsync(requireHandle(), payload, true, corr)
        }
    }

    public companion object {
        private fun createNative(model: Model, options: ChatOptions): Long =
            NativeBridge.sessionCreate(model.nativeHandle(), encodeOptions("chat", options))

        private fun encodeOptions(type: String, options: ChatOptions): String = buildJsonObject {
            put("type", type)
            options.systemPrompt?.let { put("system_prompt", it) }
            options.temperature?.let { put("temperature", it) }
            options.topP?.let { put("top_p", it) }
            options.topK?.let { put("top_k", it) }
            options.maxOutputTokens?.let { put("max_output_tokens", it) }
            options.seed?.let { put("seed", it) }
            put("keep_history", options.keepHistory)
        }.toString()

        private fun userTurn(text: String): ChatRequest = ChatRequest(
            messages = listOf(ChatMessage(role = "user", content = text)),
        )
    }
}

// -----------------------------------------------------------------------------
// Audio
// -----------------------------------------------------------------------------

public class AudioSession internal constructor(model: Model, options: AudioOptions) :
    Session(model, createNative(model, options)) {

    /** Transcribe a file already on disk, or a base64-encoded blob. */
    public fun transcribeStreaming(request: TranscribeRequest): Flow<Delta> =
        JobBridge.stream { corr ->
            NativeBridge.sessionTranscribeAsync(requireHandle(), request.toJson(), true, corr)
        }

    /** Transcribe [request] and return the full result (text, language, segments). */
    public suspend fun transcribe(request: TranscribeRequest): TranscribeResult {
        val json = JobBridge.awaitResult { corr ->
            NativeBridge.sessionTranscribeAsync(requireHandle(), request.toJson(), false, corr)
        } ?: return TranscribeResult(text = "", language = null, segments = emptyList())
        val obj = JsonCodec.parseObject(json)
        val text = obj["text"]?.jsonPrimitive?.content ?: ""
        val language = obj["language"]?.jsonPrimitive?.content
        val segments = (obj["segments"] as? JsonArray)?.mapNotNull { el ->
            (el as? JsonObject)?.let { seg ->
                TranscribeSegment(
                    text = seg["text"]?.jsonPrimitive?.content ?: "",
                    startTimeMs = seg["start_time_ms"]?.jsonPrimitive?.content?.toLongOrNull() ?: 0L,
                    endTimeMs = seg["end_time_ms"]?.jsonPrimitive?.content?.toLongOrNull() ?: 0L,
                    language = seg["language"]?.jsonPrimitive?.content,
                )
            }
        } ?: emptyList()
        return TranscribeResult(text, language, segments)
    }

    /**
     * Push a chunk of PCM audio into a live transcription session.
     *
     * The corresponding streaming call — `transcribeStreaming` — must have
     * been started first, with `{ "streaming": true }` in the request. Partial
     * and final segments arrive on that flow.
     */
    public fun pushAudio(pcm: ByteArray, sampleRate: Int, channels: Int, isFinal: Boolean = false) {
        NativeBridge.sessionPushAudio(requireHandle(), pcm, sampleRate, channels, isFinal)
    }

    public companion object {
        private fun createNative(model: Model, options: AudioOptions): Long =
            NativeBridge.sessionCreate(
                model.nativeHandle(),
                buildJsonObject {
                    put("type", "audio")
                    options.language?.let { put("language", it) }
                    options.maxOutputTokens?.let { put("max_output_tokens", it) }
                }.toString(),
            )
    }
}

// -----------------------------------------------------------------------------
// Embedding
// -----------------------------------------------------------------------------

public class EmbeddingSession internal constructor(model: Model, options: EmbeddingOptions) :
    Session(model, createNative(model, options)) {

    /** Compute embeddings for [inputs]. */
    public suspend fun embed(inputs: List<String>): EmbeddingResult {
        val request = buildJsonObject {
            putJsonArray("inputs") { inputs.forEach { add(it) } }
        }.toString()
        val json = JobBridge.awaitResult { corr ->
            NativeBridge.sessionEmbedAsync(requireHandle(), request, corr)
        } ?: return EmbeddingResult(emptyList(), 0)
        val obj = JsonCodec.parseObject(json)
        val dims = obj["dimensions"]?.jsonPrimitive?.content?.toIntOrNull() ?: 0
        val vectors = (obj["embeddings"] as? JsonArray)?.map { row ->
            (row as? JsonArray)?.map { (it as JsonPrimitive).content.toFloatOrNull() ?: 0f } ?: emptyList()
        } ?: emptyList()
        return EmbeddingResult(vectors, dims)
    }

    public companion object {
        private fun createNative(model: Model, options: EmbeddingOptions): Long =
            NativeBridge.sessionCreate(
                model.nativeHandle(),
                buildJsonObject {
                    put("type", "embedding")
                }.toString(),
            )
    }
}

// -----------------------------------------------------------------------------
// Request / result types
// -----------------------------------------------------------------------------

public data class ChatRequest(
    val messages: List<ChatMessage>,
    val tools: List<Tool> = emptyList(),
    val toolChoice: String? = null,
    val temperature: Float? = null,
    val maxOutputTokens: Int? = null,
) {
    internal fun toJson(): String = buildJsonObject {
        putJsonArray("messages") {
            messages.forEach { m ->
                addJsonObject {
                    put("role", m.role)
                    when (val content = m.content) {
                        is ChatContent.Text -> put("content", content.text)
                        is ChatContent.Parts -> putJsonArray("content") {
                            content.parts.forEach { p -> add(p.toJson()) }
                        }
                    }
                }
            }
        }
        if (tools.isNotEmpty()) {
            putJsonArray("tools") {
                tools.forEach { t ->
                    addJsonObject {
                        put("name", t.name)
                        put("description", t.description)
                        // parametersJson is a raw JSON Schema document — embed
                        // it verbatim rather than as a quoted string.
                        put(
                            "parameters",
                            kotlinx.serialization.json.Json.parseToJsonElement(t.parametersJson),
                        )
                    }
                }
            }
        }
        toolChoice?.let { put("tool_choice", it) }
        temperature?.let { put("temperature", it) }
        maxOutputTokens?.let { put("max_output_tokens", it) }
    }.toString()
}

public data class ChatMessage(
    val role: String,
    val content: ChatContent,
) {
    public constructor(role: String, content: String) : this(role, ChatContent.Text(content))
}

public sealed class ChatContent {
    public data class Text(val text: String) : ChatContent()
    public data class Parts(val parts: List<ChatContentPart>) : ChatContent()
}

public sealed class ChatContentPart {
    public data class Text(val text: String) : ChatContentPart()
    public data class Image(val path: String? = null, val dataBase64: String? = null) : ChatContentPart()
    public data class Audio(val path: String? = null, val dataBase64: String? = null) : ChatContentPart()

    internal fun toJson(): JsonElement = when (this) {
        is Text -> buildJsonObject {
            put("type", "text")
            put("text", text)
        }
        is Image -> buildJsonObject {
            put("type", "image")
            path?.let { put("path", it) }
            dataBase64?.let { put("data_base64", it) }
        }
        is Audio -> buildJsonObject {
            put("type", "audio")
            path?.let { put("path", it) }
            dataBase64?.let { put("data_base64", it) }
        }
    }
}

public data class Tool(
    val name: String,
    val description: String,
    /**
     * The JSON Schema for this tool's parameters, as a raw JSON string. Passing
     * a string keeps the type surface small; typical apps store the schema as
     * a resource asset and read it into a string.
     */
    val parametersJson: String,
)

public data class ToolResult(
    val callId: String,
    val resultJson: String,
)

public sealed class TranscribeRequest {
    public data class File(val path: String, val language: String? = null, val translate: Boolean = false) :
        TranscribeRequest()

    public data class InMemory(
        val dataBase64: String,
        val format: String = "pcm",
        val sampleRate: Int = 16000,
        val channels: Int = 1,
    ) : TranscribeRequest()

    /**
     * Start a streaming transcription that receives audio via
     * [AudioSession.pushAudio].
     */
    public data class Streaming(val language: String? = null) : TranscribeRequest()

    internal fun toJson(): String = when (this) {
        is File -> buildJsonObject {
            put("path", path)
            language?.let { put("language", it) }
            put("translate", translate)
        }.toString()
        is InMemory -> buildJsonObject {
            put("data_base64", dataBase64)
            put("format", format)
            put("sample_rate", sampleRate)
            put("channels", channels)
        }.toString()
        is Streaming -> buildJsonObject {
            put("streaming", true)
            language?.let { put("language", it) }
        }.toString()
    }
}

public data class CompleteResult(
    val text: String,
    val finishReason: FinishReason,
    /**
     * Tool calls the model wants executed, or `null` when the model made no
     * tool calls. Nullable — not defaulted to an empty list — to preserve the
     * absent-vs-empty distinction the ABI carries. In practice the empty case
     * does not appear on the wire, but a caller writing exhaustive tool
     * dispatch logic should still handle `null` explicitly.
     */
    val toolCalls: List<Delta.ToolCall>? = null,
    /** Token accounting, or `null` if the runtime did not report it. */
    val usage: Delta.Usage? = null,
    /** The raw completion JSON, exposed for callers who need unmodelled fields. */
    val rawJson: String? = null,
)

public data class EmbeddingResult(
    val embeddings: List<List<Float>>,
    val dimensions: Int,
)

public data class TranscribeResult(
    val text: String,
    /** Detected language BCP-47 tag, or null when the model reports none. */
    val language: String?,
    /** Aligned segments; empty when the runtime does not report timestamps. */
    val segments: List<TranscribeSegment>,
)

public data class TranscribeSegment(
    val text: String,
    val startTimeMs: Long,
    val endTimeMs: Long,
    val language: String?,
)
