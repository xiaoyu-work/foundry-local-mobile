// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = ExampleViewModel()
    @State private var isChoosingModel = false

    var body: some View {
        NavigationView {
            Form {
                Section("1. Local model") {
                    TextField("Absolute model directory path", text: $viewModel.modelPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("Choose model directory") {
                        isChoosingModel = true
                    }

                    Button {
                        Task { await viewModel.loadModel() }
                    } label: {
                        if viewModel.isLoading {
                            HStack {
                                ProgressView()
                                Text("Loading...")
                            }
                        } else {
                            Text("Load model")
                        }
                    }
                    .disabled(viewModel.isLoading || viewModel.isGenerating)

                    if let progress = viewModel.loadProgress {
                        ProgressView(value: progress)
                    }
                }

                Section("2. Streaming chat") {
                    TextEditor(text: $viewModel.prompt)
                        .frame(minHeight: 80)

                    Button("Send") {
                        Task { await viewModel.sendPrompt() }
                    }
                    .disabled(
                        !viewModel.isModelReady ||
                        viewModel.isLoading ||
                        viewModel.isGenerating
                    )

                    ScrollView {
                        Text(
                            viewModel.response.isEmpty
                                ? "The streamed response appears here."
                                : viewModel.response
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    }
                    .frame(minHeight: 160)
                }

                Section("Status") {
                    Text(viewModel.status)
                        .font(.footnote)
                }
            }
            .navigationTitle("Foundry Local")
        }
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
                _ = error
            }
        }
    }
}
