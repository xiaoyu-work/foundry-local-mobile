<div align="center">

# Foundry Local Mobile

**Ship on-device AI inside your mobile app — iOS, Android, Flutter and React Native.**

</div>

Foundry Local Mobile is a small C++ core plus four idiomatic SDKs (Kotlin, Swift, Dart,
TypeScript) that load a local [ONNX Runtime GenAI](https://github.com/microsoft/onnxruntime-genai)
(OGA) model and run chat inference directly on-device, entirely offline.

User data never leaves the device, responses start immediately with zero network latency,
and your app works fully offline. No per-token costs, no API keys, no backend to maintain,
and no SDK-managed model catalog or download service.

## How it works

The SDK is **path-only**. You supply a local directory containing either:

- a flat OGA model — a directory with `genai_config.json` (plus the model weights,
  tokenizer, etc.), or
- a supported `.ortpackage`-style OGA package directory — a directory with a top-level
  `manifest.json` and no `genai_config.json`, which OGA itself resolves per execution
  provider.

Getting that directory onto the device (bundled in the app, downloaded by your own code,
unzipped from your own storage) is entirely up to you. The SDK does not fetch, cache,
verify or manage models on your behalf.

```kotlin
val foundry = FoundryLocal.create(context, FoundryLocalConfig(appName = "my-app"))
val model = foundry.loadModel(path = "/data/user/0/com.example.app/files/models/qwen3-5")

val chat = model.createChatSession()
chat.completeStreaming("What is the golden ratio?").collect { delta -> print(delta.text) }
```

## Supported targets

| Target | Package | Language surface |
|---|---|---|
| **Android** | `com.microsoft.ai.foundry.local:foundry-local-mobile` (AAR) | Kotlin — suspend functions + `Flow` streaming |
| **iOS** | `FoundryLocalMobile` (Swift Package / XCFramework) | Swift — `async/await` + `AsyncThrowingStream` |
| **Flutter** | `foundry_local_mobile` (pub) | Dart — FFI, `Future` + `Stream` |
| **React Native** | `@foundry-local/react-native` (npm) | TypeScript — `Promise` + async iterators |

All four bindings expose the same path-first `loadModel(path, executionProvider,
providerOptions)` shape and sit on the same native core, so behaviour is identical across
platforms. Self-contained release bundles are implemented for every binding;
physical-device validation is still pending — see [Current maturity](#current-maturity)
below.

## Model directory requirements

`loadModel()` (`flm_manager_load_model_async` in the C ABI) needs a path to a directory
that is:

- **caller-owned** — the SDK never deletes, moves or writes into it, and it must stay
  present for as long as the model is loaded;
- **a valid OGA model directory** — either a flat model (`genai_config.json` at the top
  level) or an OGA package directory (`manifest.json` at the top level, no
  `genai_config.json`);
- **on local storage the process can read** — an app-private directory, extracted APK/
  bundle assets, or external storage the app has permission for.

Optional load options let you pin an execution provider and pass EP-specific options:

```json
{ "execution_provider": "QNN", "provider_options": { "backend_path": "libQnnHtp.so" } }
```

There is no manifest format, digest verification, resumable transfer, or variant-scoring
step performed by the SDK itself — that all lives with OGA (for package directories) or
with whatever process put the files on disk.

## Architecture

```
┌───────────────────────────────────────────────────────────────────────────┐
│  App code                                                                 │
├──────────────┬──────────────┬───────────────┬─────────────────────────────┤
│  Kotlin API  │  Swift API   │  Dart API     │  TypeScript API             │
├──────────────┼──────────────┼───────────────┼─────────────────────────────┤
│  JNI bridge  │  Swift C     │  dart:ffi     │  TurboModule (reuses the    │
│  (C++)       │  interop     │  (direct)     │  Kotlin + Swift bindings)   │
├──────────────┴──────────────┴───────────────┴─────────────────────────────┤
│  flm_* — flat, FFI-friendly C ABI (version 2)                              │
│  handles · async jobs · callbacks · JSON metadata                          │
├───────────────────────────────────────────────────────────────────────────┤
│  Mobile core (C++20): job pool · device profile · lifecycle                │
├───────────────────────────────────────────────────────────────────────────┤
│  ONNX Runtime GenAI (linked directly) — model load · tokenize · generate   │
└───────────────────────────────────────────────────────────────────────────┘
```

See [docs/architecture.md](docs/architecture.md) for the full breakdown.

## Current maturity

Be precise about what is proven and what is not:

| Capability | Status |
|---|---|
| Load a local OGA model directory (flat or package) | Implemented |
| Text chat completion, streaming deltas | Implemented — Windows end-to-end tested against the OGA `qwen3-5` fixture model |
| Multi-turn history (export/restore/undo/clear) | Implemented and Windows E2E-tested |
| Audio transcription (batch and streaming) | Implemented directly with OGA; compatible-model E2E and phone validation still pending |
| Embeddings | Implemented for `hidden_states`-style outputs with float32, float16 and bfloat16 conversion; model E2E pending |
| Multimodal chat input | Implemented for local-path or base64 image/audio content through OGA processors; real-model/device E2E pending |
| Structured tool-call and reasoning deltas | Implemented for models exposing OGA BOT/EOT and BOR/EOR special-token IDs; compatible-model E2E pending |
| Android build | Compiles for `arm64-v8a` and `x86_64`; on-device E2E not yet proven |
| iOS build | Compiles against the C ABI; on-device E2E not yet proven |
| Flutter / React Native | Self-contained Android/Apple release packaging implemented; device validation pending |

There is no catalog, no remote model download, no transport layer, and no SDK-managed
cache deletion anywhere in this SDK — those concerns belong entirely to your app.

## Build summary

The Android/iOS native builds compile the ONNX Runtime GenAI source tree pinned at commit
[`9d336e4`](https://github.com/microsoft/onnxruntime-genai/commit/9d336e4db4e49eeceda909517b882c0d73cc6c86),
staged by `scripts/fetch_onnxruntime_genai.sh`.

```bash
./scripts/fetch_onnxruntime_genai.sh   # stage OGA source into third_party/
./scripts/build.sh linux               # native core, for local iteration
./scripts/build.sh android             # arm64-v8a, x86_64
./scripts/build.sh apple               # XCFramework (macOS host only)
```

Full details, prerequisites and troubleshooting: [docs/building.md](docs/building.md).

## Quickstart

<details open>
<summary><strong>Kotlin (Android)</strong></summary>

```kotlin
// FoundryLocal.create is a suspend fun; call from a coroutine
// (lifecycleScope, viewModelScope, or your own).
val foundry = FoundryLocal.create(context, FoundryLocalConfig(appName = "my-app"))

// Point the SDK at a local model directory you already put on disk.
val model = foundry.loadModel(path = modelDir.absolutePath)

val chat = model.createChatSession()
chat.completeStreaming("What is the golden ratio?").collect { delta ->
    print(delta.text)
}
```

</details>

<details open>
<summary><strong>Swift (iOS)</strong></summary>

```swift
let foundry = try FoundryLocal(config: .init(appName: "my-app"))

// Point the SDK at a local model directory you already put on disk.
let model = try await foundry.loadModel(at: "/path/to/models/qwen3-5")

let chat = try model.createChatSession()
for try await delta in chat.completeStreaming("What is the golden ratio?") {
    print(delta.text, terminator: "")
}
```

</details>

<details open>
<summary><strong>Dart (Flutter)</strong></summary>

```dart
final foundry = await FoundryLocal.create(const FoundryLocalConfig(appName: 'my-app'));

// Point the SDK at a local model directory you already put on disk.
final model = await foundry.loadModel('/path/to/models/qwen3-5');

final chat = model.createChatSession();
await for (final delta in chat.completeStreaming('What is the golden ratio?')) {
  if (delta is TextDelta) stdout.write(delta.text);
}
```

</details>

<details open>
<summary><strong>TypeScript (React Native)</strong></summary>

```ts
const foundry = await FoundryLocal.create({ appName: 'my-app' });

// Point the SDK at a local model directory you already put on disk.
const model = await foundry.loadModel('/path/to/models/qwen3-5');

const chat = model.createChatSession();
for await (const delta of chat.completeStreaming('What is the golden ratio?')) {
  process.stdout.write(delta.text);
}
```

</details>

## Repository layout

```
core/                 C++ core + flat C ABI (flm_*) that every binding calls
  include/            Public headers — the single source of truth for the ABI
  src/                Implementation directly over the ONNX Runtime GenAI C API
bindings/
  android/            Gradle library: JNI bridge + Kotlin API
  ios/                Swift Package: C interop + Swift API
  flutter/            Dart FFI plugin
  react-native/       TurboModule (Kotlin + Swift) + TypeScript API
samples/              Android, SwiftUI iOS and React Native example apps
bindings/flutter/example/
                      Flutter example app (standard plugin layout)
scripts/              Cross-compilation and packaging scripts
docs/                 Architecture, model directory requirements, platform notes
```

All four public SDKs have runnable examples that load a caller-provided model
directory and stream chat output; see [samples/README.md](samples/README.md).

## Documentation

- [Architecture](docs/architecture.md) — how the layers fit together and why
- [Model packages](docs/model-packages.md) — flat OGA models vs. OGA package directories
- [Building from source](docs/building.md) — NDK / Xcode toolchains and packaging
- [Platform support](docs/platform-support.md) — OS versions, ABIs, accelerators

## Limitations

- No catalog, no remote model download/transport, no SDK-managed cache or cache deletion.
- Audio transcription, embeddings, multimodal chat and structured tool-call parsing are
  implemented but still need compatible-model and physical-device E2E coverage.
- Android and iOS on-device (physical hardware) end-to-end validation is not yet proven;
  today's proof point is a Windows E2E run against the OGA `qwen3-5` fixture model.
- Flutter and React Native ship self-contained Android and Apple native artifacts;
  physical-device validation is still pending.

## License

MIT — see [LICENSE](LICENSE). Models you load are subject to their own license terms.
