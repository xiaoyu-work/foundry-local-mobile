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
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * State machine driving the sample UI.
 *
 * The stages match the path-only model loading workflow: initialise the SDK,
 * provide a local model path, load, then chat.
 */
sealed interface UiState {
    /** Awaiting the user to provide a model path and click "Load". */
    data class NeedsConfig(
        val modelPath: String,
        val message: String? = null,
    ) : UiState

    /** `model.load()` is running. */
    data class Loading(val name: String) : UiState

    /** Model is loaded; the chat session is ready. */
    data class Ready(val name: String, val history: List<ChatTurn>) : UiState

    /** A streaming completion is in flight. */
    data class Generating(val name: String, val history: List<ChatTurn>, val pending: String) : UiState

    /** Something went wrong. */
    data class Error(val stage: String, val message: String, val detail: String?) : UiState
}

data class ChatTurn(val role: String, val text: String)

class SdkViewModel(app: Application) : AndroidViewModel(app) {

    private val _state = MutableStateFlow<UiState>(
        UiState.NeedsConfig(
            modelPath = BuildConfig.DEFAULT_MODEL_PATH,
        )
    )
    val state: StateFlow<UiState> = _state.asStateFlow()

    private var foundry: FoundryLocal? = null
    private var model: Model? = null
    private var session: com.microsoft.ai.foundry.local.mobile.ChatSession? = null

    /**
     * Initialise the SDK and load the caller-provided model.
     */
    fun prepare(modelPath: String) {
        val path = modelPath.trim()
        if (path.isBlank()) {
            _state.update {
                UiState.NeedsConfig(
                    modelPath = modelPath,
                    message = "A model directory path is required.",
                )
            }
            return
        }
        _state.value = UiState.Loading(path.substringAfterLast('/'))
        viewModelScope.launch {
            try {
                val fl = FoundryLocal.create(
                    getApplication(),
                    FoundryLocalConfig(appName = "foundry-local-sample"),
                )
                foundry = fl
                val m = fl.loadModel(path)
                model = m
                val chat = m.createChatSession()
                session = chat
                val info = m.info
                _state.value = UiState.Ready(
                    name = info.displayName ?: info.name,
                    history = emptyList(),
                )
            } catch (t: Throwable) {
                closeResources()
                _state.value = UiState.Error("model load", messageOf(t), detailOf(t))
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
                closeResources()
                _state.value = UiState.Error("chat", messageOf(t), detailOf(t))
            }
        }
    }

    /** Return to model selection and release the current native resources. */
    fun reset() {
        closeResources()
        _state.value = UiState.NeedsConfig(modelPath = BuildConfig.DEFAULT_MODEL_PATH)
    }

    override fun onCleared() {
        closeResources()
    }

    private fun closeResources() {
        try { session?.close() } catch (_: Throwable) {}
        session = null
        try { model?.close() } catch (_: Throwable) {}
        model = null
        try { foundry?.close() } catch (_: Throwable) {}
        foundry = null
    }

    private fun messageOf(t: Throwable): String =
        (t as? FoundryLocalException)?.let {
            "${it.javaClass.simpleName} (status=${it.status}): ${it.messageOrEmpty}"
        } ?: (t.message ?: t.javaClass.simpleName)

    private fun detailOf(t: Throwable): String? =
        (t as? FoundryLocalException)?.detailJson
}
