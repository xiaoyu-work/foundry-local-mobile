// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.samples

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/**
 * Root switching composable for the path-only model loading sample.
 */
@Composable
fun SampleScreen(
    state: UiState,
    onPrepare: (modelPath: String) -> Unit,
    onLoadAndChat: (prompt: String) -> Unit,
    onSend: (prompt: String) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp)
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("Foundry Local — Android sample", style = MaterialTheme.typography.headlineSmall)
        when (state) {
            is UiState.NeedsConfig -> ConfigPanel(state, onPrepare)
            is UiState.Configured -> ConfiguredPanel(state, onLoadAndChat)
            is UiState.Loading -> LoadingPanel(state)
            is UiState.Ready -> ChatPanel(state, onSend, pending = null)
            is UiState.Generating -> ChatPanel(
                state = UiState.Ready(state.name, state.history),
                onSend = { },
                pending = state.pending,
                busy = true,
            )
            is UiState.Error -> ErrorPanel(state)
        }
    }
}

@Composable
private fun ConfigPanel(state: UiState.NeedsConfig, onPrepare: (String) -> Unit) {
    var modelPath by rememberSaveable { mutableStateOf(state.modelPath) }

    Text(
        "Provide the path to a local ONNX Runtime GenAI model directory.",
        style = MaterialTheme.typography.bodyMedium,
    )
    OutlinedTextField(
        value = modelPath, onValueChange = { modelPath = it },
        label = { Text("Model directory path") },
        placeholder = { Text("/data/.../models/qwen2.5-0.5b") },
        modifier = Modifier.fillMaxWidth(),
        singleLine = true,
    )
    state.message?.let {
        Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
    }
    Button(onClick = { onPrepare(modelPath) }, modifier = Modifier.fillMaxWidth()) {
        Text("Prepare SDK")
    }
}

@Composable
private fun ConfiguredPanel(state: UiState.Configured, onLoadAndChat: (String) -> Unit) {
    var prompt by rememberSaveable { mutableStateOf("Say hello in one sentence.") }

    LabelledCard("SDK ready") {
        Text("Model path: ${state.modelPath}", style = MaterialTheme.typography.bodyMedium)
        Text("Device: ${state.deviceSummary}", style = MaterialTheme.typography.bodySmall)
    }
    OutlinedTextField(
        value = prompt, onValueChange = { prompt = it },
        label = { Text("First prompt (will run after load)") },
        modifier = Modifier.fillMaxWidth(),
    )
    Button(onClick = { onLoadAndChat(prompt) }, modifier = Modifier.fillMaxWidth()) {
        Text("Load model and send")
    }
}

@Composable
private fun LoadingPanel(state: UiState.Loading) {
    LabelledCard("Loading ${state.name}") {
        LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
        Text("Loading model into memory…", style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
private fun ChatPanel(state: UiState.Ready, onSend: (String) -> Unit, pending: String?, busy: Boolean = false) {
    var input by rememberSaveable { mutableStateOf("") }
    LabelledCard("Chat with ${state.name}") {
        state.history.forEach { turn ->
            Column(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                Text(
                    turn.role.uppercase(),
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.Bold,
                )
                Text(
                    turn.text,
                    style = MaterialTheme.typography.bodyMedium,
                    fontFamily = if (turn.role == "assistant") FontFamily.Monospace else FontFamily.Default,
                )
            }
        }
        if (!pending.isNullOrEmpty()) {
            Column(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                Text("ASSISTANT (streaming)", style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold)
                Text(pending, style = MaterialTheme.typography.bodyMedium, fontFamily = FontFamily.Monospace)
            }
        }
    }
    OutlinedTextField(
        value = input,
        onValueChange = { input = it },
        label = { Text(if (busy) "Generating…" else "Next prompt") },
        enabled = !busy,
        modifier = Modifier.fillMaxWidth(),
    )
    Button(
        onClick = { if (input.isNotBlank()) { onSend(input); input = "" } },
        enabled = !busy && input.isNotBlank(),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text("Send")
    }
}

@Composable
private fun ErrorPanel(state: UiState.Error) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer),
    ) {
        Column(modifier = Modifier.padding(12.dp)) {
            Text("Failed at ${state.stage}", fontWeight = FontWeight.Bold)
            Text(state.message)
            state.detail?.let {
                Spacer(Modifier.height(6.dp))
                Text("detail: $it", style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)
            }
        }
    }
}

@Composable
private fun LabelledCard(title: String, content: @Composable () -> Unit) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(12.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(6.dp))
            content()
        }
    }
}
