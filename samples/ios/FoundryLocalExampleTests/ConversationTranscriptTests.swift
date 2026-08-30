// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import XCTest
@testable import FoundryLocalExample

final class ConversationTranscriptTests: XCTestCase {
    func testBeginTurnCreatesUserMessageAndThinkingAssistant() {
        var transcript = ConversationTranscript()

        transcript.beginTurn("Hello")

        XCTAssertEqual(transcript.messages.count, 2)
        XCTAssertEqual(transcript.messages[0].role, .user)
        XCTAssertEqual(transcript.messages[0].text, "Hello")
        XCTAssertFalse(transcript.messages[0].isThinking)
        XCTAssertEqual(transcript.messages[1].role, .assistant)
        XCTAssertEqual(transcript.messages[1].text, "")
        XCTAssertTrue(transcript.messages[1].isThinking)
    }

    func testVisibleTextAccumulatesAndEndsThinkingState() {
        var transcript = ConversationTranscript()
        transcript.beginTurn("Hello")

        transcript.receiveReasoning()
        transcript.receiveText("On-device ")
        transcript.receiveText("inference")

        XCTAssertEqual(transcript.messages.last?.text, "On-device inference")
        XCTAssertEqual(transcript.messages.last?.role, .assistant)
        XCTAssertFalse(transcript.messages.last?.isThinking ?? true)
    }

    func testVisibleTextDropsLeadingBlankLinesButKeepsParagraphBreaks() {
        var transcript = ConversationTranscript()
        transcript.beginTurn("Hello")

        transcript.receiveText("\r")
        transcript.receiveText("\n\tOn-device answer")
        transcript.receiveText("\r\n\r\nSecond paragraph")

        XCTAssertEqual(
            transcript.messages.last?.text,
            "\tOn-device answer\r\n\r\nSecond paragraph"
        )
    }

    func testFinishingWithoutVisibleTextReplacesThinkingPlaceholder() {
        var transcript = ConversationTranscript()
        transcript.beginTurn("Hello")

        transcript.finishTurn()

        XCTAssertEqual(
            transcript.messages.last?.text,
            "No visible response was generated."
        )
        XCTAssertFalse(transcript.messages.last?.isThinking ?? true)
    }

    func testFailureEndsThinkingAndExplainsTheFailedTurn() {
        var transcript = ConversationTranscript()
        transcript.beginTurn("Hello")

        transcript.failTurn("Runtime unavailable")

        XCTAssertEqual(
            transcript.messages.last?.text,
            "Generation failed: Runtime unavailable"
        )
        XCTAssertFalse(transcript.messages.last?.isThinking ?? true)
    }
}

@MainActor
final class ExampleViewModelTests: XCTestCase {
    func testInitialStateIsReadyForSetupWithoutFakeConversationContent() {
        let viewModel = ExampleViewModel()

        XCTAssertEqual(viewModel.modelDisplayName, "Local model")
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(viewModel.prompt, "")
        XCTAssertFalse(viewModel.isModelReady)
    }
}
