// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import SwiftUI
import UniformTypeIdentifiers

private extension Color {
    static let monochromeAccent = Color(uiColor: .label)
    static let onMonochromeAccent = Color(uiColor: .systemBackground)
}

struct ContentView: View {
    @StateObject private var viewModel = ExampleViewModel()
    @State private var isChoosingModel = false

    var body: some View {
        NavigationView {
            Group {
                if viewModel.isModelReady {
                    ChatView(viewModel: viewModel)
                } else {
                    SetupView(
                        viewModel: viewModel,
                        onChooseDirectory: { isChoosingModel = true }
                    )
                }
            }
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
        .tint(.monochromeAccent)
        .fileImporter(
            isPresented: $isChoosingModel,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    viewModel.selectModelDirectory(url)
                }
            case .failure(let error):
                viewModel.modelPath = ""
                print("Model directory selection failed: \(error.localizedDescription)")
            }
        }
    }
}

private struct SetupView: View {
    @ObservedObject var viewModel: ExampleViewModel
    let onChooseDirectory: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "cpu")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(.onMonochromeAccent)
                    .frame(width: 64, height: 64)
                    .background(Color.monochromeAccent)
                    .clipShape(Circle())

                Text("Chat with a local model")
                    .font(.title2.weight(.semibold))

                Text(
                    "Choose an ONNX Runtime GenAI model directory. " +
                    "Messages stay private and are generated on this device."
                )
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

                TextField("Absolute model directory path", text: $viewModel.modelPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Button("Choose model directory", action: onChooseDirectory)
                    .buttonStyle(.bordered)

                Button {
                    Task { await viewModel.loadModel() }
                } label: {
                    HStack {
                        if viewModel.isLoading {
                            ProgressView()
                                .tint(.onMonochromeAccent)
                        }
                        Text(viewModel.isLoading ? "Loading..." : "Load model")
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.onMonochromeAccent)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isLoading || viewModel.modelPath.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty)

                if let progress = viewModel.loadProgress, viewModel.isLoading {
                    ProgressView(value: progress)
                        .tint(.monochromeAccent)
                }

                Text(viewModel.status)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
    }
}

private struct ChatView: View {
    @ObservedObject var viewModel: ExampleViewModel

    var body: some View {
        VStack(spacing: 0) {
            ModelHeader(
                name: viewModel.modelDisplayName,
                status: viewModel.status,
                busy: viewModel.isGenerating
            )
            Divider()
            MessageList(messages: viewModel.messages)
            Divider()
            Composer(
                text: $viewModel.prompt,
                enabled: !viewModel.isGenerating,
                onSend: {
                    Task { await viewModel.sendPrompt() }
                }
            )
        }
        .background(Color(uiColor: .systemBackground))
    }
}

private struct ModelHeader: View {
    let name: String
    let status: String
    let busy: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .foregroundColor(.onMonochromeAccent)
                .frame(width: 40, height: 40)
                .background(Color.monochromeAccent)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if busy {
                ProgressView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityIdentifier("model-header")
    }
}

private struct MessageList: View {
    let messages: [ConversationMessage]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if messages.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 42))
                            .foregroundColor(.monochromeAccent)
                        Text("How can I help?")
                            .font(.title2.weight(.semibold))
                        Text("Responses are generated locally on this device.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                    .padding(24)
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(16)
                }
            }
            .onChange(of: messages) { updatedMessages in
                guard let lastID = updatedMessages.last?.id else {
                    return
                }
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
        .accessibilityIdentifier("message-list")
    }
}

private struct MessageBubble: View {
    let message: ConversationMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .assistant {
                Text("Q")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.onMonochromeAccent)
                    .frame(width: 30, height: 30)
                    .background(Color.monochromeAccent)
                    .clipShape(Circle())
            } else {
                Spacer(minLength: 48)
            }

            Group {
                if message.isThinking {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Thinking...")
                    }
                } else {
                    Text(message.text)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .foregroundColor(
                message.role == .user ? .onMonochromeAccent : .primary
            )
            .background(
                message.role == .user
                    ? Color.monochromeAccent
                    : Color(uiColor: .secondarySystemBackground)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20))

            if message.role == .assistant {
                Spacer(minLength: 48)
            }
        }
        .frame(
            maxWidth: .infinity,
            alignment: message.role == .user ? .trailing : .leading
        )
    }
}

private struct Composer: View {
    @Binding var text: String
    let enabled: Bool
    let onSend: () -> Void

    private var canSend: Bool {
        enabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                enabled ? "Message the model..." : "Please wait...",
                text: $text,
                onCommit: send
            )
            .disabled(!enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 22))

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.onMonochromeAccent)
                    .frame(width: 42, height: 42)
                    .background(canSend ? Color.monochromeAccent : Color.secondary)
                    .clipShape(Circle())
            }
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityIdentifier("chat-composer")
    }

    private func send() {
        guard canSend else {
            return
        }
        onSend()
    }
}
