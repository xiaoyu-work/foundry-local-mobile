// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.mobile

/**
 * Create a [ChatSession] on this loaded model, run [block] with it, and
 * release the session even on exception or cancellation.
 *
 * Prefer this over the two-step `createChatSession()` + `use { }` pattern:
 * it removes the intermediate variable and makes the leak-free path the
 * shortest one to write.
 *
 * ```kotlin
 * val reply = model.withChatSession { chat ->
 *     chat.complete("Explain the golden ratio.").text
 * }
 * ```
 *
 * The lambda is `inline`, so a suspending caller can invoke suspending
 * methods on the session inside the block:
 *
 * ```kotlin
 * suspend fun summarize(model: Model, prompt: String): String =
 *     model.withChatSession { chat -> chat.complete(prompt).text }
 * ```
 *
 * A long-lived session that outlives a single function — for example one
 * held across a ViewModel's lifetime — should still be closed by hand in
 * `onCleared()`; this helper is for the one-shot case.
 */
public inline fun <R> Model.withChatSession(
    options: ChatOptions = ChatOptions(),
    block: (ChatSession) -> R,
): R = createChatSession(options).use(block)

/**
 * Create an [AudioSession] on this loaded model, run [block] with it, and
 * release the session even on exception. See [withChatSession] for
 * discussion.
 *
 * ```kotlin
 * val transcript = model.withAudioSession { audio ->
 *     audio.transcribe(TranscribeRequest.File(path = "/sdcard/note.wav")).text
 * }
 * ```
 */
public inline fun <R> Model.withAudioSession(
    options: AudioOptions = AudioOptions(),
    block: (AudioSession) -> R,
): R = createAudioSession(options).use(block)

/**
 * Create an [EmbeddingSession] on this loaded model, run [block] with it,
 * and release the session even on exception. See [withChatSession] for
 * discussion.
 *
 * ```kotlin
 * val vector: List<Float> = model.withEmbeddingSession { emb ->
 *     emb.embed(listOf("hello world")).embeddings.first()
 * }
 * ```
 */
public inline fun <R> Model.withEmbeddingSession(
    options: EmbeddingOptions = EmbeddingOptions(),
    block: (EmbeddingSession) -> R,
): R = createEmbeddingSession(options).use(block)
