// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.samples

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
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
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.microsoft.ai.foundry.local.mobile.ModelVariant
import com.microsoft.ai.foundry.local.mobile.Progress

/**
 * Root switching composable. Each stage of the state machine renders its own
 * sub-screen; the ViewModel drives the transitions.
 */
@Composable
fun SampleScreen(
    state: UiState,
    onPrepare: (name: String, url: String, authHeader: String) -> Unit,
    onStartDownload: (authHeader: String) -> Unit,
    onCancelDownload: () -> Unit,
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
            is UiState.Configured -> ConfiguredPanel(state, onStartDownload)
            is UiState.Downloading -> DownloadPanel(state, onCancelDownload)
            is UiState.VariantsResolved -> VariantsPanel(state, onLoadAndChat)
            is UiState.Loading -> LoadingPanel(state)
            is UiState.Ready -> ChatPanel(state, onSend, pending = null)
            is UiState.Generating -> ChatPanel(
                state = UiState.Ready(state.name, state.history),
                onSend = { /* disabled while generating */ },
                pending = state.pending,
                busy = true,
            )
            is UiState.Error -> ErrorPanel(state)
        }
    }
}

@Composable
private fun ConfigPanel(state: UiState.NeedsConfig, onPrepare: (String, String, String) -> Unit) {
    var name by rememberSaveable { mutableStateOf(state.name) }
    var url by rememberSaveable { mutableStateOf(state.url) }
    var auth by rememberSaveable { mutableStateOf(state.authHeader) }

    Text(
        "Point the sample at your own model source. See README for how to store " +
            "these values in local.properties instead of typing them each launch.",
        style = MaterialTheme.typography.bodyMedium,
    )
    OutlinedTextField(
        value = name, onValueChange = { name = it },
        label = { Text("Model name") },
        placeholder = { Text("e.g. phi-4-mini") },
        modifier = Modifier.fillMaxWidth(),
        singleLine = true,
    )
    OutlinedTextField(
        value = url, onValueChange = { url = it },
        label = { Text("Manifest URL") },
        placeholder = { Text("https://…/manifest.json") },
        modifier = Modifier.fillMaxWidth(),
        singleLine = true,
    )
    OutlinedTextField(
        value = auth, onValueChange = { auth = it },
        label = { Text("Authorization header (optional)") },
        placeholder = { Text("Bearer <token>") },
        modifier = Modifier.fillMaxWidth(),
        singleLine = true,
    )
    state.message?.let {
        Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
    }
    Button(onClick = { onPrepare(name, url, auth) }, modifier = Modifier.fillMaxWidth()) {
        Text("Prepare SDK")
    }
}

@Composable
private fun ConfiguredPanel(state: UiState.Configured, onStartDownload: (String) -> Unit) {
    var auth by rememberSaveable { mutableStateOf("") }

    LabelledCard("SDK ready") {
        Text("Model name: ${state.name}", style = MaterialTheme.typography.bodyMedium)
        Text("Source URL: ${state.url}", style = MaterialTheme.typography.bodySmall)
        Text("Device: ${state.deviceSummary}", style = MaterialTheme.typography.bodySmall)
    }
    OutlinedTextField(
        value = auth, onValueChange = { auth = it },
        label = { Text("Authorization header (optional)") },
        placeholder = { Text("Bearer <token>") },
        modifier = Modifier.fillMaxWidth(),
        singleLine = true,
    )
    Button(onClick = { onStartDownload(auth) }, modifier = Modifier.fillMaxWidth()) {
        Text("Add model source")
    }
}

@Composable
private fun DownloadPanel(state: UiState.Downloading, onCancel: () -> Unit) {
    LabelledCard("Downloading ${state.name}") {
        val p = state.progress
        if (p == null) {
            Text("Starting…", style = MaterialTheme.typography.bodyMedium)
            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
        } else {
            val pct = p.percent.coerceIn(0f, 100f)
            LinearProgressIndicator(progress = { pct / 100f }, modifier = Modifier.fillMaxWidth())
            Text(
                "${"%.1f".format(pct)}%  ·  ${humanBytes(p.completedBytes)} / ${humanBytes(p.totalBytes)}",
                style = MaterialTheme.typography.bodyMedium,
            )
            if (p.bytesPerSecond > 0) {
                Text(
                    "${humanBytes(p.bytesPerSecond)}/s  ·  ETA ${humanEta(p.etaMs)}",
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            p.stage?.let { Text("Stage: $it", style = MaterialTheme.typography.bodySmall) }
            p.detail?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        }
    }
    OutlinedButton(onClick = onCancel, modifier = Modifier.fillMaxWidth()) {
        Text("Cancel")
    }
}

@Composable
private fun VariantsPanel(state: UiState.VariantsResolved, onLoadAndChat: (String) -> Unit) {
    LabelledCard("Model files ready") {
        Text(
            "Downloaded ${humanBytes(state.bytesDownloaded)}" +
                (if (state.wasCached) " (fully served from cache)" else ""),
            style = MaterialTheme.typography.bodyMedium,
        )
        Text("Model: ${state.name}", style = MaterialTheme.typography.bodySmall)
        state.selectedVariantId?.let {
            Text(
                "Selected variant: $it",
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Bold,
            )
        }
    }

    if (state.variants.isEmpty()) {
        Text(
            "This model is a flat file, not a package — no variant selection took place.",
            style = MaterialTheme.typography.bodySmall,
        )
    } else {
        Text("Variants considered", style = MaterialTheme.typography.titleSmall)
        state.variants.forEach { v ->
            VariantCard(v, isSelected = v.id == state.selectedVariantId)
        }
    }

    var prompt by rememberSaveable { mutableStateOf("Say hello in one sentence.") }
    Spacer(Modifier.height(4.dp))
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
private fun VariantCard(v: ModelVariant, isSelected: Boolean) {
    val bg = if (isSelected) {
        MaterialTheme.colorScheme.primaryContainer
    } else {
        MaterialTheme.colorScheme.surfaceVariant
    }
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = bg),
    ) {
        Column(modifier = Modifier.padding(12.dp)) {
            Text(
                v.id + if (isSelected) "  ← selected" else "",
                fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal,
                style = MaterialTheme.typography.bodyMedium,
            )
            Text(
                "${v.executionProvider} on ${v.device}, platform=${v.platform}, size=${humanBytes(v.downloadSizeBytes)}",
                style = MaterialTheme.typography.bodySmall,
            )
            Text(
                "compatible=${v.isCompatible}, score=${v.compatibilityScore}" +
                    (if (v.isCached) ", cached" else ""),
                style = MaterialTheme.typography.bodySmall,
            )
            if (v.compatibilityString.isNotBlank()) {
                Text("policy: ${v.compatibilityString}", style = MaterialTheme.typography.bodySmall)
            }
            v.incompatibilityReason?.let {
                Text(
                    "incompatible: $it",
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }
    }
}

@Composable
private fun LoadingPanel(state: UiState.Loading) {
    LabelledCard("Loading ${state.name}") {
        LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
        Text("Warming up the runtime…", style = MaterialTheme.typography.bodySmall)
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

private fun humanBytes(b: Long): String {
    if (b < 0) return "?"
    if (b < 1024) return "$b B"
    val units = arrayOf("KiB", "MiB", "GiB", "TiB")
    var v = b.toDouble() / 1024
    var i = 0
    while (v >= 1024 && i < units.size - 1) { v /= 1024; i++ }
    return "%.1f %s".format(v, units[i])
}

private fun humanEta(ms: Long): String {
    if (ms <= 0) return "?"
    val s = ms / 1000
    if (s < 60) return "${s}s"
    val m = s / 60
    if (m < 60) return "${m}m ${s % 60}s"
    return "${m / 60}h ${m % 60}m"
}
