// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.samples

import android.app.Application
import android.os.Looper
import com.microsoft.ai.foundry.local.mobile.ChatSession
import com.microsoft.ai.foundry.local.mobile.Delta
import com.microsoft.ai.foundry.local.mobile.FoundryLocal
import com.microsoft.ai.foundry.local.mobile.Model
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.Mockito.mock
import org.mockito.Mockito.verify
import org.mockito.Mockito.`when`
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf

@RunWith(RobolectricTestRunner::class)
class SdkViewModelTest {

    @Test
    fun generationFailureReleasesNativeResources() {
        val viewModel = SdkViewModel(RuntimeEnvironment.getApplication() as Application)
        val foundry = mock(FoundryLocal::class.java)
        val model = mock(Model::class.java)
        val session = mock(ChatSession::class.java)
        val failure = IllegalStateException("generation failed")

        setField(viewModel, "foundry", foundry)
        setField(viewModel, "model", model)
        setField(viewModel, "session", session)
        mutableState(viewModel).value = UiState.Ready("Qwen3", emptyList())
        `when`(session.completeStreaming("Hello")).thenReturn(flow { throw failure })

        viewModel.sendTurn("Hello")
        shadowOf(Looper.getMainLooper()).idle()

        verify(session).close()
        verify(model).close()
        verify(foundry).close()
        assertTrue(viewModel.state.value is UiState.Error)
    }

    @Test
    fun streamedResponseDropsLeadingBlankLinesButKeepsParagraphBreaks() {
        val viewModel = SdkViewModel(RuntimeEnvironment.getApplication() as Application)
        val session = mock(ChatSession::class.java)

        setField(viewModel, "session", session)
        mutableState(viewModel).value = UiState.Ready("Qwen3", emptyList())
        `when`(session.completeStreaming("Hello")).thenReturn(
            flowOf(
                Delta.Text("\n"),
                Delta.Text("\n    On-device answer"),
                Delta.Text("\n\nSecond paragraph"),
            )
        )

        viewModel.sendTurn("Hello")
        shadowOf(Looper.getMainLooper()).idle()

        val ready = viewModel.state.value as UiState.Ready
        assertEquals(
            "    On-device answer\n\nSecond paragraph",
            ready.history.last().text,
        )
    }

    private fun setField(target: Any, name: String, value: Any) {
        target.javaClass.getDeclaredField(name).apply {
            isAccessible = true
            set(target, value)
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun mutableState(viewModel: SdkViewModel): MutableStateFlow<UiState> =
        viewModel.javaClass.getDeclaredField("_state").run {
            isAccessible = true
            get(viewModel) as MutableStateFlow<UiState>
        }
}
