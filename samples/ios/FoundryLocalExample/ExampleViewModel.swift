// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import Foundation
import FoundryLocal

struct ConversationMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    var text: String
    var isThinking = false
}

private struct AssistantTextBuffer: Equatable {
    private(set) var text = ""
    private var pendingPrefix = ""
    private var started = false

    mutating func append(_ fragment: String) {
        guard !fragment.isEmpty else {
            return
        }
        if started {
            text += fragment
            return
        }

        pendingPrefix += fragment
        guard let firstVisible = pendingPrefix.rangeOfCharacter(
            from: .whitespacesAndNewlines.inverted
        )?.lowerBound else {
            return
        }

        let leadingWhitespace = pendingPrefix[..<firstVisible]
        if let lastLineBreak = leadingWhitespace.utf8.lastIndex(
            where: { $0 == 0x0A || $0 == 0x0D }
        ) {
            let contentStart = pendingPrefix.utf8.index(after: lastLineBreak)
            text += String(
                decoding: pendingPrefix.utf8[contentStart...],
                as: UTF8.self
            )
        } else {
            text += pendingPrefix
        }
        pendingPrefix = ""
        started = true
    }
}

struct ConversationTranscript: Equatable {
    private(set) var messages: [ConversationMessage] = []
    private var assistantText = AssistantTextBuffer()

    mutating func beginTurn(_ prompt: String) {
        assistantText = AssistantTextBuffer()
        messages.append(ConversationMessage(role: .user, text: prompt))
        messages.append(
            ConversationMessage(role: .assistant, text: "", isThinking: true)
        )
    }

    mutating func receiveReasoning() {
        let index = activeAssistantIndex
        messages[index].isThinking = messages[index].text.isEmpty
    }

    mutating func receiveText(_ fragment: String) {
        let index = activeAssistantIndex
        assistantText.append(fragment)
        messages[index].text = assistantText.text
        messages[index].isThinking = assistantText.text.isEmpty
    }

    mutating func finishTurn() {
        let index = activeAssistantIndex
        if messages[index].text.isEmpty {
            messages[index].text = "No visible response was generated."
        }
        messages[index].isThinking = false
    }

    mutating func failTurn(_ message: String) {
        let index = activeAssistantIndex
        if messages[index].text.isEmpty {
            messages[index].text = "Generation failed: \(message)"
        }
        messages[index].isThinking = false
    }

    private var activeAssistantIndex: Int {
        guard let index = messages.indices.last, messages[index].role == .assistant else {
            preconditionFailure("A streamed delta requires an active assistant message.")
        }
        return index
    }
}

@MainActor
final class ExampleViewModel: ObservableObject {
    @Published var modelPath = ""
    @Published var prompt = ""
    @Published private(set) var transcript = ConversationTranscript()
    @Published private(set) var modelDisplayName = "Local model"
    @Published private(set) var status = "Choose an ONNX Runtime GenAI model directory."
    @Published private(set) var loadProgress: Double?
    @Published private(set) var isLoading = false
    @Published private(set) var isGenerating = false
    @Published private(set) var isModelReady = false

    private var foundry: FoundryLocal?
    private var model: Model?
    private var chat: ChatSession?
    private var securityScopedModelURL: URL?

    var messages: [ConversationMessage] {
        transcript.messages
    }

    func selectModelDirectory(_ url: URL) {
        securityScopedModelURL?.stopAccessingSecurityScopedResource()
        securityScopedModelURL = nil

        if url.startAccessingSecurityScopedResource() {
            securityScopedModelURL = url
        }
        modelPath = url.path
        status = "Selected \(url.lastPathComponent)."
    }

    func loadModel() async {
        let path = modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            status = "A model directory path is required."
            return
        }

        isLoading = true
        isModelReady = false
        loadProgress = 0
        transcript = ConversationTranscript()
        modelDisplayName = path.components(separatedBy: "/").last ?? "Local model"
        status = "Loading model..."
        closeModel()

        do {
            let sdk: FoundryLocal
            if let foundry {
                sdk = foundry
            } else {
                sdk = try FoundryLocal(
                    config: FoundryLocalConfig(appName: "foundry-local-ios-example")
                )
                foundry = sdk
            }

            let loaded = try await sdk.loadModel(at: path) { [weak self] progress in
                Task { @MainActor in
                    self?.loadProgress = Double(progress.percent) / 100
                    self?.status = "Loading \(progress.percent.formatted())% - \(progress.stage)"
                }
            }
            let info = try loaded.info()
            let session = try loaded.createChatSession(
                ChatSessionOptions(
                    systemPrompt: "You are a concise assistant.",
                    temperature: 0.7,
                    maxOutputTokens: 512
                )
            )

            model = loaded
            chat = session
            isModelReady = true
            loadProgress = 1
            let name = info.displayName ?? info.name
            modelDisplayName = name
            status = "On-device - \(info.executionProvider ?? "default EP")"
        } catch {
            closeModel()
            loadProgress = nil
            status = "Load failed: \(error.localizedDescription)"
        }
        isLoading = false
    }

    func sendPrompt() async {
        guard !isGenerating else {
            return
        }
        guard let chat else {
            status = "Load a model first."
            return
        }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            status = "Enter a prompt."
            return
        }

        isGenerating = true
        transcript.beginTurn(text)
        prompt = ""
        status = "Generating on device..."
        defer {
            isGenerating = false
        }

        do {
            for try await delta in chat.completeStreaming(text) {
                switch delta {
                case .text(let fragment):
                    transcript.receiveText(fragment)
                case .reasoning:
                    transcript.receiveReasoning()
                case .completed(let reason, let usage):
                    if let usage {
                        status = "On-device - \(reason) - \(usage.completionTokens) tokens"
                    } else {
                        status = "On-device - \(reason)"
                    }
                case .toolCall, .usage:
                    break
                }
            }
            transcript.finishTurn()
        } catch {
            let message = error.localizedDescription
            transcript.failTurn(message)
            status = "Generation failed: \(message)"
        }
    }

    private func closeModel() {
        chat?.close()
        chat = nil
        model?.close()
        model = nil
    }
}
