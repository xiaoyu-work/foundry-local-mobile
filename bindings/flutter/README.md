# foundry_local_mobile

On-device AI for Flutter. This package is a `dart:ffi` plugin over the
`foundry-local-mobile` C++ core, which itself wraps the Microsoft
[Foundry Local](https://github.com/microsoft/Foundry-Local) ONNX Runtime GenAI
runtime.

Everything runs on the device. There is no backend, no per-token cost and no
network required for inference. The plugin ships:

- streaming chat with tool calling,
- speech-to-text (batch and streaming),
- embeddings,
- a catalog with per-device variant selection,
- background-safe model download planning,
- OS-level lifecycle bridging (memory pressure, thermal, connectivity).

## Requirements

| | |
|-|-|
| Dart | `>=3.1.0` — `NativeCallable.listener` is required |
| Flutter | `>=3.13.0` |
| Android | minSdk 21, NDK 26, 64-bit ARM |
| iOS | 13.0+ |
| macOS | 10.15+ |

## Install

```yaml
dependencies:
  foundry_local_mobile: ^0.1.0
```

Nothing else needs to be added on Android or iOS — the plugin builds the native
core from source and the FFI binding is registered automatically.

## Quickstart

```dart
import 'package:foundry_local_mobile/foundry_local_mobile.dart';

Future<void> main() async {
  final foundry = await FoundryLocal.create();

  // Discover, download and load a chat model.
  final model = await foundry.catalog.getModelById('phi-4-mini-instruct');
  await model.downloadAndWait();
  await for (final _ in model.load()) {}

  final chat = model.createChatSession(
    options: const ChatSessionOptions(
      systemPrompt: 'You are a helpful assistant.',
      temperature: 0.7,
    ),
  );

  final request = ChatRequest(messages: [
    ChatMessage.user('Explain FFI callbacks in one sentence.'),
  ]);

  await for (final delta in chat.completeStreaming(request)) {
    if (delta is TextDelta) stdout.write(delta.text);
    if (delta is CompletedDelta) break;
  }

  await chat.release();
  await model.release();
  await foundry.dispose();
}
```

## Model sources

`Model` can come from a **bundled** on-device source (a directory the app
already ships) or a **remote** URL the transport fetches.

```dart
await foundry.addModelSource(
  BundledModelSource(
    name: 'my-bundled-model',
    path: '/path/to/model/dir',
  ),
);

await foundry.addModelSource(
  RemoteModelSource(
    name: 'my-remote-catalog',
    url: 'https://example.com/catalog.json',
  ),
);
```

See [`docs/model-sources.md`](../../docs/model-sources.md) at the repo root for
the full contract.

## Transport

The C++ core never performs HTTP directly. It plans downloads and calls out
through `flm_transport`, which the plugin binds to a Dart implementation.

The default is **`DartHttpTransport`**, built on `dart:io HttpClient`. It:

- honours `Range` semantics: when the core asks to resume, `offset > 0` sends
  `Range: bytes=<offset>-` and the writer opens the destination in append
  mode;
- streams the body when `destination_path` is null;
- always calls `flm_transport_report_complete` exactly once, including when
  the request was cancelled or threw. Missing that call **hangs a job thread
  in the core**, so the guard is deliberate.

**Backgrounding tradeoff.** A pure-Dart transport dies when the OS suspends
the app, which is fatal for a multi-gigabyte model download. Apps that expect
to download models in the background should provide their own transport
implementation that delegates to a platform-native background download
manager (Android WorkManager / `DownloadManager`, iOS
`URLSessionConfiguration.background`). Plug it in at `FoundryLocal.create`:

```dart
final foundry = await FoundryLocal.create(
  transport: MyBackgroundTransport(),
);
```

The plugin ships the Dart transport as the default because it works
everywhere, and swapping in a native transport is a per-app decision that
depends on WorkManager identity conventions and iOS background modes the
plugin cannot know about.

## FFI, threads and callbacks (why this plugin is structured the way it is)

The C ABI is asynchronous: every long-running operation returns an `flm_job`
handle and delivers progress + completion via C callbacks. Those callbacks
fire on the core's job-pool threads, never on the Dart isolate.

The plugin uses `NativeCallable.listener` for **every** callback. The
listener wakes the isolate's event loop and marshals the invocation onto it.
`Pointer.fromFunction` and `NativeCallable.isolateLocal` would crash the VM
the first time the core called back because they enter the VM synchronously
on the calling thread.

Three ABI callbacks return `int32_t` (`flm_progress_callback`,
`flm_delta_callback`, `flm_transport_send`). `NativeCallable.listener`
supports only void callbacks. To bridge the gap the plugin ships a tiny C
shim (`src/flm_dart_bridge.c`) whose functions match the ABI signature,
forward to a stored void listener and return zero. Cancellation flows through
`flm_job_cancel` and transport failure through
`flm_transport_report_complete`, so a synchronous return value from the
listener is never actually needed.

## Lifecycle bridging

The plugin registers a `WidgetsBindingObserver` and a small
`MethodChannel`/`EventChannel` pair to forward:

- foreground / background transitions,
- `didHaveMemoryPressure`,
- Android `ComponentCallbacks2.TRIM_MEMORY_*`,
- iOS `didReceiveMemoryWarning` and thermal state,
- low-power mode,
- metered vs unmetered connectivity.

They map onto `flm_manager_notify_lifecycle`. The data path never uses the
method channel; only these low-frequency signals do.

## API reference

The public surface lives in `package:foundry_local_mobile/foundry_local_mobile.dart`.
Highlights:

- `FoundryLocal` — root object, one per process.
- `Catalog` — model discovery.
- `Model` — one shipped model (`download`, `load`, `unload`, `delete`).
- `ModelPackage` — a model made of multiple per-device variants.
- `ChatSession` — `complete`, `completeStreaming`, `submitToolResults`,
  history export/restore.
- `AudioSession` — batch file transcription and streaming microphone input.
- `EmbeddingSession` — single-batch text embeddings.
- `FlmTransport` — pluggable HTTP transport.

## License

MIT. See [LICENSE](LICENSE).
