# FoundryLocal for iOS, iPadOS, macOS, and visionOS

Swift SDK for on-device inference with ONNX Runtime GenAI models.

The SDK is **path-only**: callers provide a local model directory and the SDK
loads it directly through ONNX Runtime GenAI. There is no catalog, no SDK-managed
download, and no transport layer.

- iOS 15 · iPadOS 15 · Mac Catalyst 15 · macOS 12 · visionOS 1
- Swift 5.9+, Xcode 15+
- Swift 6 strict-concurrency clean

---

## Quick start

```swift
import FoundryLocal

let sdk = try FoundryLocal(config: FoundryLocalConfig(appName: "Notes"))

// Load a model from a local directory.
let model = try await sdk.loadModel(
    at: "/path/to/models/qwen2.5-0.5b",
    executionProvider: "CoreMLExecutionProvider"
)

// Chat.
let chat = try model.createChatSession()
for try await delta in chat.completeStreaming("Explain vector databases in one line.") {
    print(delta.text, terminator: "")
}
```

## Building the XCFramework

```bash
./scripts/build_apple.sh
cp -R build/apple/FoundryLocalMobile.xcframework bindings/ios/Frameworks/
```

## Lifecycle wiring

Automatic. `FoundryLocal` observes system notifications for foreground/background
transitions and memory pressure, unloading models as needed.

## Logging

```swift
try FoundryLocal.setLogLevel(.debug)
```

## Error handling

Every call throws `FoundryLocalError`. Discriminate on `.code` for structured
error handling.

```swift
do {
    let model = try await sdk.loadModel(at: path)
} catch let error as FoundryLocalError where error.code == .memoryPressure {
    // Not enough memory to load; try a smaller model.
}
```
