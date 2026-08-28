// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import Foundation
import FoundryLocal

@MainActor
final class ExampleViewModel: ObservableObject {
    @Published var modelPath = ""
    @Published var prompt = "In one sentence, what is on-device inference?"
    @Published private(set) var response = ""
    @Published private(set) var status = "Choose an ONNX Runtime GenAI model directory."
    @Published private(set) var loadProgress: Double?
    @Published private(set) var isLoading = false
    @Published private(set) var isGenerating = false
    @Published private(set) var isModelReady = false

    private var foundry: FoundryLocal?
    private var model: Model?
    private var chat: ChatSession?
    private var securityScopedModelURL: URL?

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
        response = ""
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
                    maxOutputTokens: 256
                )
            )

            model = loaded
            chat = session
            isModelReady = true
            loadProgress = 1
            let name = info.displayName ?? info.name
            status = "Ready: \(name) (\(info.executionProvider ?? "default EP"))"
        } catch {
            closeModel()
            loadProgress = nil
            status = "Load failed: \(error.localizedDescription)"
        }
        isLoading = false
    }

    func sendPrompt() async {
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
        response = ""
        status = "Generating..."
        do {
            for try await delta in chat.completeStreaming(text) {
                switch delta {
                case .text(let fragment):
                    response += fragment
                case .completed(let reason, let usage):
                    if let usage {
                        status = "Done: \(reason) - \(usage.completionTokens) generated tokens"
                    } else {
                        status = "Done: \(reason)"
                    }
                case .reasoning, .toolCall, .usage:
                    break
                }
            }
        } catch {
            status = "Generation failed: \(error.localizedDescription)"
        }
        isGenerating = false
    }

    private func closeModel() {
        chat?.close()
        chat = nil
        model?.close()
        model = nil
    }
}
