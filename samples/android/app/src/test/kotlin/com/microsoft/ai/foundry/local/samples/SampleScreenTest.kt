// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.samples

import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class SampleScreenTest {

    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun streamedResponseStaysVisibleAfterLongHistory() {
        val history = List(24) { index ->
            ChatTurn(
                role = if (index % 2 == 0) "user" else "assistant",
                text = "Earlier message $index",
            )
        }

        composeRule.setContent {
            MaterialTheme {
                SampleScreen(
                    state = UiState.Generating(
                        name = "Qwen3",
                        history = history,
                        pending = "Newest streamed response",
                    ),
                    onPrepare = {},
                    onSend = {},
                    onReset = {},
                )
            }
        }

        composeRule
            .onNodeWithText("Newest streamed response")
            .assertIsDisplayed()
    }

    @Test
    @Config(qualifiers = "w320dp-h240dp")
    fun recoveryActionStaysVisibleWithLongErrorDetails() {
        composeRule.setContent {
            MaterialTheme {
                SampleScreen(
                    state = UiState.Error(
                        stage = "chat",
                        message = "Generation failed.",
                        detail = "Detailed native error. ".repeat(80),
                    ),
                    onPrepare = {},
                    onSend = {},
                    onReset = {},
                )
            }
        }

        val rootBounds = composeRule
            .onRoot()
            .fetchSemanticsNode()
            .boundsInRoot
        val actionBounds = composeRule
            .onNodeWithText("Choose another model")
            .fetchSemanticsNode()
            .boundsInRoot

        assertTrue(
            "Recovery action must fit inside the visible root: action=$actionBounds root=$rootBounds",
            actionBounds.top >= rootBounds.top && actionBounds.bottom <= rootBounds.bottom,
        )
    }
}
