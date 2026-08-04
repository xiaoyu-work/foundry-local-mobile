// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.samples

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.microsoft.ai.foundry.local.mobile.FoundryLocal
import com.microsoft.ai.foundry.local.mobile.FoundryLocalConfig
import com.microsoft.ai.foundry.local.mobile.FoundryLocalException
import com.microsoft.ai.foundry.local.mobile.Model
import com.microsoft.ai.foundry.local.mobile.ModelPackage
import com.microsoft.ai.foundry.local.mobile.ModelSource
import com.microsoft.ai.foundry.local.mobile.ModelVariant
import com.microsoft.ai.foundry.local.mobile.PackageVariants
import com.microsoft.ai.foundry.local.mobile.Progress
import com.microsoft.ai.foundry.local.mobile.VariantConstraints
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * State machine driving the sample UI.
 *
 * The stages match the task the sample is meant to demonstrate: initialise,
 * configure a remote source, resolve which variant this device will use,
 * download with cancellable progress, load, chat.
 *
 * Errors surface as [UiState.Error]; the previous stage is retained on
 * [state.lastKnownStage] so a user can retry without starting over.
 */
sealed interface UiState {
    /** Awaiting the user to fill in URL + headers and click "Prepare". */
    data class NeedsConfig(
        val name: String,
        val url: String,
        val authHeader: String,
        val message: String? = null,
    ) : UiState

    /** SDK initialised; ready to add the model source. */
    data class Configured(
        val name: String,
        val url: String,
        val deviceSummary: String,
    ) : UiState

    /** `flm_manager_add_model_source_async` is running; progress and cancel are live. */
    data class Downloading(
        val name: String,
        val progress: Progress?,
    ) : UiState

    /** Files are on disk; here is the variant the SDK picked and the alternatives it rejected. */
    data class VariantsResolved(
        val name: String,
        val selectedVariantId: String?,
        val variants: List<ModelVariant>,
        val bytesDownloaded: Long,
        val wasCached: Boolean,
    ) : UiState

    /** `model.load()` is running. */
    data class Loading(val name: String) : UiState

    /** Model is loaded; the chat session is ready. */
    data class Ready(val name: String, val history: List<ChatTurn>) : UiState

    /** A streaming completion is in flight; [pending] is the assistant text so far. */
    data class Generating(val name: String, val history: List<ChatTurn>, val pending: String) : UiState

    /**
     * Something went wrong. [detail] carries the raw
     * `FoundryLocalException.detailJson` when available so the app can surface
     * a machine-readable payload alongside the human message.
     */
    data class Error(val stage: String, val message: String, val detail: String?) : UiState
}

data class ChatTurn(val role: String, val text: String)

class SdkViewModel(app: Application) : AndroidViewModel(app) {

    private val _state = MutableStateFlow<UiState>(
        UiState.NeedsConfig(
            name = BuildConfig.DEFAULT_MODEL_NAME,
            url = BuildConfig.DEFAULT_MODEL_URL,
            authHeader = BuildConfig.DEFAULT_AUTH_HEADER,
        )
    )
    val state: StateFlow<UiState> = _state.asStateFlow()

    // The SDK, the model, and the session are borrowed by the UI once they
    // exist and released in onCleared(). The order matters: session before
    // model before manager.
    private var foundry: FoundryLocal? = null
    private var model: Model? = null
    private var session: com.microsoft.ai.foundry.local.mobile.ChatSession? = null

    // Download job kept so the cancel button can call job.cancel(); JobBridge
    // wires this straight through to flm_job_cancel.
    private var downloadJob: Job? = null

    /**
     * Called from the configuration form after the user has entered URL and
     * headers. Initialises the manager, prints the device profile so the
     * demo can show which EPs the SDK sees, and moves to [UiState.Configured].
     */
    fun prepare(name: String, url: String, authHeader: String) {
        if (name.isBlank() || url.isBlank()) {
            _state.update {
                UiState.NeedsConfig(
                    name = name, url = url, authHeader = authHeader,
                    message = "Both a model name and a URL are required.",
                )
            }
            return
        }
        viewModelScope.launch {
            try {
                // FoundryLocal.create is a suspend fun that dispatches its
                // filesystem work internally, so this call is safe on any
                // dispatcher — the viewModelScope's Main is fine.
                val fl = FoundryLocal.create(
                    getApplication(),
                    FoundryLocalConfig(appName = "foundry-local-sample"),
                )
                foundry = fl
                _state.value = UiState.Configured(
                    name = name.trim(),
                    url = url.trim(),
                    deviceSummary = fl.deviceProfile.summary,
                )
            } catch (t: Throwable) {
                _state.value = UiState.Error("prepare", messageOf(t), detailOf(t))
            }
        }
    }

    /** Kick off the download. Idempotent per launch: only runs when we are Configured. */
    fun startDownload(authHeader: String) {
        val cfg = _state.value as? UiState.Configured ?: return
        val fl = foundry ?: return

        _state.value = UiState.Downloading(cfg.name, progress = null)

        downloadJob = viewModelScope.launch {
            try {
                val headers = if (authHeader.isNotBlank()) {
                    mapOf("Authorization" to authHeader)
                } else {
                    emptyMap()
                }
                // Constraints applied against the manifest before any bytes
                // transfer: NPU if available, otherwise GPU, otherwise CPU,
                // and no variant larger than one gigabyte. Matches the story
                // the docs tell about VariantConstraints.
                val constraints = VariantConstraints(
                    maxDownloadBytes = 1L * 1024 * 1024 * 1024,
                    allowedDevices = null,
                )
                val result = fl.addModelSource(
                    ModelSource.Remote(
                        name = cfg.name,
                        url = cfg.url,
                        headers = headers,
                        constraints = constraints,
                    ),
                    onProgress = { progress ->
                        _state.update { current ->
                            if (current is UiState.Downloading) current.copy(progress = progress)
                            else current
                        }
                    },
                )
                // The sample only demonstrates package sources, so the null
                // case is a bug we would want to raise loudly rather than
                // silently swallow. requireModel() throws IllegalStateException
                // with an actionable message that names the source and the
                // on-disk path, which the Error panel below will surface.
                model = result.requireModel()

                // Snapshot the variants the SDK saw. If the model happens to
                // be a flat file the list is empty; if it is a package this
                // is where the "why was this variant chosen" answer comes
                // from — is_compatible / incompatibility_reason /
                // compatibility_score for every candidate.
                val variants: PackageVariants? = model?.asPackage()?.variants
                _state.value = UiState.VariantsResolved(
                    name = cfg.name,
                    selectedVariantId = result.variantId?.ifBlank { null }
                        ?: variants?.selectedVariantId,
                    variants = variants?.variants.orEmpty(),
                    bytesDownloaded = result.bytesDownloaded,
                    wasCached = result.wasCached,
                )
            } catch (_: CancellationException) {
                _state.value = UiState.NeedsConfig(
                    name = cfg.name, url = cfg.url, authHeader = authHeader,
                    message = "Download cancelled.",
                )
            } catch (t: Throwable) {
                _state.value = UiState.Error("download", messageOf(t), detailOf(t))
            }
        }
    }

    /**
     * Cancel the download. The coroutine cancellation propagates through
     * [com.microsoft.ai.foundry.local.mobile.internal.JobBridge] to
     * `flm_job_cancel`; the SDK finishes cleanup and we land in
     * [UiState.NeedsConfig] via the [CancellationException] branch above.
     */
    fun cancelDownload() {
        downloadJob?.cancel()
    }

    /**
     * Load the model into memory. This is a separate step from the download
     * so the sample can display the variant summary between them, which is
     * the "why did the SDK pick this variant" moment the task calls for.
     */
    fun loadAndChat(prompt: String) {
        val current = _state.value as? UiState.VariantsResolved ?: return
        val m = model ?: return
        _state.value = UiState.Loading(current.name)
        viewModelScope.launch {
            try {
                m.load()
                val chat = m.createChatSession()
                session = chat
                val history = listOf(ChatTurn("user", prompt))
                _state.value = UiState.Generating(current.name, history, pending = "")
                var acc = StringBuilder()
                chat.completeStreaming(prompt).collect { delta ->
                    acc.append(delta.text)
                    _state.update { st ->
                        if (st is UiState.Generating) st.copy(pending = acc.toString()) else st
                    }
                }
                _state.value = UiState.Ready(
                    current.name,
                    history + ChatTurn("assistant", acc.toString()),
                )
            } catch (t: Throwable) {
                _state.value = UiState.Error("load-or-chat", messageOf(t), detailOf(t))
            }
        }
    }

    /** Send another user turn once we are in [UiState.Ready]. */
    fun sendTurn(prompt: String) {
        val ready = _state.value as? UiState.Ready ?: return
        val chat = session ?: return
        val history = ready.history + ChatTurn("user", prompt)
        _state.value = UiState.Generating(ready.name, history, pending = "")
        viewModelScope.launch {
            try {
                val acc = StringBuilder()
                chat.completeStreaming(prompt).collect { delta ->
                    acc.append(delta.text)
                    _state.update { st ->
                        if (st is UiState.Generating) st.copy(pending = acc.toString()) else st
                    }
                }
                _state.value = UiState.Ready(
                    ready.name,
                    history + ChatTurn("assistant", acc.toString()),
                )
            } catch (t: Throwable) {
                _state.value = UiState.Error("chat", messageOf(t), detailOf(t))
            }
        }
    }

    override fun onCleared() {
        // AutoCloseable order matters: session before model before manager.
        try { session?.close() } catch (_: Throwable) {}
        try { model?.close() } catch (_: Throwable) {}
        try { foundry?.close() } catch (_: Throwable) {}
    }

    private fun messageOf(t: Throwable): String =
        (t as? FoundryLocalException)?.let {
            "${it.javaClass.simpleName} (status=${it.status}): ${it.messageOrEmpty}"
        } ?: (t.message ?: t.javaClass.simpleName)

    private fun detailOf(t: Throwable): String? =
        (t as? FoundryLocalException)?.detailJson
}
