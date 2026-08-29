// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.samples

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowUpward
import androidx.compose.material.icons.rounded.ChatBubbleOutline
import androidx.compose.material.icons.rounded.Memory
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

private val FoundryGreen = Color(0xFF10A37F)

@Composable
fun SampleScreen(
    state: UiState,
    onPrepare: (modelPath: String) -> Unit,
    onSend: (prompt: String) -> Unit,
    onReset: () -> Unit,
) {
    when (state) {
        is UiState.NeedsConfig -> SetupScreen(state, onPrepare)
        is UiState.Loading -> ChatScreen(
            modelName = state.name.ifBlank { "Local model" },
            status = "Loading on device...",
            history = emptyList(),
            pending = null,
            busy = true,
            onSend = onSend,
        )
        is UiState.Ready -> ChatScreen(
            modelName = state.name,
            status = "On-device - Ready",
            history = state.history,
            pending = null,
            busy = false,
            onSend = onSend,
        )
        is UiState.Generating -> ChatScreen(
            modelName = state.name,
            status = "Generating on device...",
            history = state.history,
            pending = state.pending,
            busy = true,
            onSend = onSend,
        )
        is UiState.Error -> ErrorScreen(state, onReset)
    }
}

@Composable
private fun SetupScreen(
    state: UiState.NeedsConfig,
    onPrepare: (String) -> Unit,
) {
    var modelPath by rememberSaveable { mutableStateOf(state.modelPath) }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.surface),
        contentAlignment = Alignment.Center,
    ) {
        Card(
            modifier = Modifier
                .fillMaxWidth()
                .padding(24.dp)
                .widthIn(max = 520.dp),
        ) {
            Column(
                modifier = Modifier.padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                ModelAvatar(icon = Icons.Rounded.Memory)
                Text(
                    "Chat with a local model",
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    "Choose an ONNX Runtime GenAI model directory. After loading, " +
                        "the app switches to a private on-device conversation.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                OutlinedTextField(
                    value = modelPath,
                    onValueChange = { modelPath = it },
                    label = { Text("Model directory") },
                    placeholder = { Text("/data/local/tmp/qwen3") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                )
                state.message?.let {
                    Text(
                        it,
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
                Button(
                    onClick = { onPrepare(modelPath) },
                    enabled = modelPath.isNotBlank(),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("Load model")
                }
            }
        }
    }
}

@Composable
private fun ChatScreen(
    modelName: String,
    status: String,
    history: List<ChatTurn>,
    pending: String?,
    busy: Boolean,
    onSend: (String) -> Unit,
) {
    val listState = rememberLazyListState()
    val tailIndex = history.size + if (pending != null) 1 else 0

    LaunchedEffect(tailIndex, pending) {
        if (tailIndex > 0) {
            listState.scrollToItem(tailIndex)
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.surface),
    ) {
        ModelHeader(modelName, status, busy)
        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
        if (history.isEmpty() && pending == null) {
            Welcome(modifier = Modifier.weight(1f), loading = busy)
        } else {
            LazyColumn(
                state = listState,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                items(history) { turn -> MessageBubble(turn) }
                if (pending != null) {
                    item {
                        MessageBubble(
                            ChatTurn("assistant", pending),
                            thinking = pending.isEmpty(),
                        )
                    }
                }
                item { Spacer(Modifier.height(1.dp)) }
            }
        }
        ChatComposer(enabled = !busy, onSend = onSend)
    }
}

@Composable
private fun ModelHeader(modelName: String, status: String, busy: Boolean) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ModelAvatar(icon = Icons.Rounded.ChatBubbleOutline)
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                modelName,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                status,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.labelMedium,
            )
        }
        if (busy) {
            CircularProgressIndicator(modifier = Modifier.size(22.dp), strokeWidth = 2.dp)
        }
    }
}

@Composable
private fun ModelAvatar(icon: androidx.compose.ui.graphics.vector.ImageVector) {
    Box(
        modifier = Modifier
            .size(40.dp)
            .background(FoundryGreen, CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = Color.White)
    }
}

@Composable
private fun Welcome(modifier: Modifier, loading: Boolean) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(
            if (loading) Icons.Rounded.Memory else Icons.Rounded.ChatBubbleOutline,
            contentDescription = null,
            modifier = Modifier.size(48.dp),
            tint = FoundryGreen,
        )
        Spacer(Modifier.height(16.dp))
        Text(
            if (loading) "Preparing your local AI" else "How can I help?",
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            "Messages are generated locally on this device.",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun MessageBubble(turn: ChatTurn, thinking: Boolean = false) {
    val isUser = turn.role == "user"
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = if (isUser) Arrangement.End else Arrangement.Start,
        verticalAlignment = Alignment.Top,
    ) {
        if (!isUser) {
            Box(
                modifier = Modifier
                    .size(30.dp)
                    .background(FoundryGreen, CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Text("Q", color = Color.White, fontWeight = FontWeight.Bold)
            }
            Spacer(Modifier.width(10.dp))
        }
        Box(
            modifier = Modifier
                .fillMaxWidth(0.78f)
                .background(
                    if (isUser) FoundryGreen else MaterialTheme.colorScheme.surfaceContainerHighest,
                    RoundedCornerShape(20.dp),
                )
                .padding(horizontal = 16.dp, vertical = 12.dp),
        ) {
            if (thinking) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(modifier = Modifier.size(14.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(8.dp))
                    Text("Thinking...")
                }
            } else {
                Text(
                    turn.text,
                    color = if (isUser) Color.White else MaterialTheme.colorScheme.onSurface,
                    style = MaterialTheme.typography.bodyLarge,
                )
            }
        }
    }
}

@Composable
private fun ChatComposer(
    enabled: Boolean,
    onSend: (String) -> Unit,
) {
    var input by rememberSaveable { mutableStateOf("") }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .navigationBarsPadding()
            .imePadding()
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.Bottom,
    ) {
        OutlinedTextField(
            value = input,
            onValueChange = { input = it },
            enabled = enabled,
            placeholder = { Text(if (enabled) "Message the model..." else "Please wait...") },
            modifier = Modifier.weight(1f),
            maxLines = 4,
            shape = RoundedCornerShape(24.dp),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
            keyboardActions = KeyboardActions(
                onSend = {
                    if (enabled && input.isNotBlank()) {
                        onSend(input.trim())
                        input = ""
                    }
                },
            ),
        )
        Spacer(Modifier.width(8.dp))
        FilledIconButton(
            onClick = {
                onSend(input.trim())
                input = ""
            },
            enabled = enabled && input.isNotBlank(),
        ) {
            Icon(Icons.Rounded.ArrowUpward, contentDescription = "Send")
        }
    }
}

@Composable
private fun ErrorScreen(state: UiState.Error, onReset: () -> Unit) {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Card(
            modifier = Modifier
                .fillMaxWidth()
                .padding(24.dp)
                .widthIn(max = 520.dp),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.errorContainer,
            ),
        ) {
            Column(
                modifier = Modifier.padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text(
                    "Could not ${state.stage}",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(state.message)
                state.detail?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall)
                }
                OutlinedButton(onClick = onReset) {
                    Text("Choose another model")
                }
            }
        }
    }
}
