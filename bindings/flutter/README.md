# foundry_local_mobile

On-device AI for Flutter. This package is a `dart:ffi` plugin over the
`foundry-local-mobile` C++ core, which loads local ONNX Runtime GenAI (OGA)
models directly — no Microsoft Foundry Local runtime, catalog, or download
dependency.

Everything runs on the device. There is no backend, no per-token cost and no
network required for inference. The plugin ships:

- local model loading from caller-owned directories,
- streaming chat and multi-turn history,
- batch/streaming audio transcription and text embeddings,
- OS-level lifecycle bridging (memory pressure, thermal, connectivity).

Audio and embedding paths still require compatible-model and physical-device
validation. Multimodal chat input and structured tool-call event parsing remain
incomplete.

## Requirements

| | |
|-|-|
| Dart | `>=3.1.0` — `NativeCallable.listener` is required |
| Flutter | `>=3.13.0` |
| Android | minSdk 26, NDK 27, 64-bit ARM |
| iOS | 15.0+ |
| macOS | 12.0+ |

## Install

```yaml
dependencies:
  foundry_local_mobile: ^0.2.0
```

Nothing else needs to be added on Android or iOS — the plugin builds the native
core from source and the FFI binding is registered automatically.

## Quickstart

```dart
import 'dart:io';
import 'package:foundry_local_mobile/foundry_local_mobile.dart';

Future<void> main() async {
  final foundry = await FoundryLocal.create(
    const FoundryLocalConfig(appName: 'my-app'),
  );

  final model = await foundry.loadModel(
    '/path/to/models/qwen2.5-0.5b',
    onProgress: (p) => print('${p.stage} ${p.percent}%'),
  );

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

  chat.release();
  model.dispose();
  await foundry.dispose();
}
```

## Loading models

Models are loaded from app-owned local directories. Call
[`FoundryLocal.loadModel`](lib/src/foundry_local.dart) with an absolute path to
an ONNX Runtime GenAI model directory:

```dart
final model = await foundry.loadModel(
  '/path/to/model/dir',
  executionProvider: 'QNN',
  providerOptions: const {'backend_path': 'libQnnHtp.so'},
  onProgress: (p) => print('${p.percent}% ${p.stage}'),
);
```

`loadModel()` validates the directory, loads the model through the native
runtime, and returns a ready-to-use `Model`. If you later call
[`Model.unload`](lib/src/model.dart), you can bring the same handle back with
[`Model.load`](lib/src/model.dart).

## FFI, threads and callbacks

The C ABI is asynchronous: every long-running operation returns an `flm_job`
handle and delivers progress, deltas, and completion via C callbacks. Those
callbacks fire on the core's job-pool threads, never on the Dart isolate.

The plugin uses `NativeCallable.listener` for every callback. The listener wakes
the isolate's event loop and marshals the invocation onto it.
`Pointer.fromFunction` and `NativeCallable.isolateLocal` would crash the VM the
first time the core called back because they enter the VM synchronously on the
calling thread.

Two ABI callbacks return `int32_t` (`flm_progress_callback`,
`flm_delta_callback`). `NativeCallable.listener` supports only void callbacks.
To bridge the gap the plugin ships a tiny C shim (`src/flm_dart_bridge.c`) whose
functions match the ABI signature, forward to a stored void listener and return
zero. Cancellation flows through `flm_job_cancel`, so a synchronous return
value from the listener is never needed.

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

- `FoundryLocal` — root object, one per process. Provides `loadModel`.
- `Model` — one loaded model (`load`, `unload`, `getInfo`, `path`, session
  creation, `dispose`).
- `ChatSession` — `complete`, `completeStreaming`, `submitToolResults`,
  history export/restore. Text streaming and multi-turn history are
  implemented; structured tool-call event parsing is not complete yet.
- `AudioSession` — batch file transcription and streaming microphone input.
  Not yet implemented; calls return an error from the native core.
- `EmbeddingSession` — single-batch text embeddings. Not yet implemented;
  calls return an error from the native core.

## License

MIT. See [LICENSE](LICENSE).
