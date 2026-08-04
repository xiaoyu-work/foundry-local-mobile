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
- declarative per-device variant selection on model packages,
- a device-local catalog for inspecting what is already on disk,
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
import 'dart:io';
import 'package:foundry_local_mobile/foundry_local_mobile.dart';

Future<void> main() async {
  final foundry = await FoundryLocal.create();

  // Register a model the app either bundles or fetches from its own storage.
  // See "Model sources" below for the full contract.
  final model = await foundry.addModelSource(
    RemoteModelSource(
      name: 'phi-4-mini',
      url: 'https://storage.example.com/phi-4-mini/manifest.json',
    ),
  );

  final load = await model.load(
    onProgress: (p) => print('${p.stage} ${p.percent}%'),
  );
  print('Loaded ${load.bytes} bytes from ${load.path}');

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
  model.release();
  await foundry.dispose();
}
```

## Model sources

Models on mobile are **always** provided by the app: there is no built-in
"download from a public catalog" flow. `flm_model_download_async` returns
`FLM_ERROR_NOT_IMPLEMENTED` for anything not already on the device — the
Foundry Local catalog only publishes desktop CUDA/DirectML/OpenVINO builds,
which are useless on a phone.

Give the SDK a model by registering a `ModelSource`:

- **Bundled** — a directory the app already ships (assets extracted to
  `getApplicationSupportDirectory()`, an in-app-purchase bundle, an
  encrypted archive you decrypted yourself).
- **Remote** — an HTTPS manifest the transport (see below) fetches on demand.

```dart
// A model shipped inside the app.
final localModel = await foundry.addModelSource(
  BundledModelSource(
    name: 'phi-4-mini-bundled',
    path: '/path/to/model/dir',
  ),
);

// A model the app hosts on its own storage.
final remoteModel = await foundry.addModelSource(
  RemoteModelSource(
    name: 'phi-4-mini-remote',
    url: 'https://storage.example.com/phi-4-mini/manifest.json',
  ),
);
```

Both `ModelSource` kinds accept two optional flags that pass straight through
to the core, both defaulting to `true`:

- `resume: true` — resume a partial download rather than restart it. Turn
  off only when the origin server mishandles `Range` requests, which is
  fatal on a multi-gigabyte download that keeps hitting network transitions.
- `verifyChecksums: true` — SHA-256-check every downloaded file. **Should
  stay on** for anything you did not just build yourself: the runtime
  `mmap`s the file and executes operators from it.

Once a source resolves, [`Model.load`](lib/src/model.dart) makes it resident:

```dart
final result = await model.load(
  onProgress: (p) => print('${p.stage} ${p.percent}%'),
);
print('Loaded ${result.bytes} B from ${result.path}');
```

`load()` does **not** download on demand. If the underlying model files
were not fetched during `addModelSource`, load rejects with a
`FoundryLocalException` carrying `FLM_ERROR_NOT_IMPLEMENTED`. This is
deliberate: mobile apps must consciously choose when to spend the user's
bandwidth.

See [`docs/model-sources.md`](../../docs/model-sources.md) at the repo root
for the full contract.

## Model packages (per-device variants)

A **model package** is one alias in front of several execution-provider /
device / precision variants of the same model (e.g. a CPU-int4 build for
older phones, a QNN build for Snapdragon NPUs, a CoreML build for Apple
Neural Engine). Point [`FoundryLocal.addModelSource`](lib/src/foundry_local.dart)
at a package manifest and set [`VariantConstraints`](lib/src/models/model_source.dart)
on the source — the core scores this device against every variant **before**
any weights transfer, so a phone never spends bytes on a build it cannot run.

```dart
final model = await foundry.addModelSource(
  const RemoteModelSource(
    name: 'qwen2.5-0.5b',
    url: 'https://models.example.com/qwen2.5-0.5b/manifest.json',
    constraints: VariantConstraints(
      maxDownloadBytes: 800 * 1024 * 1024,
      allowedDevices: [FlmDevice.npu, FlmDevice.gpu, FlmDevice.cpu],
    ),
  ),
  onProgress: (p) => print('${p.percent}%'),
);

// What was actually chosen, and what else the package offered.
final package = model.package;
if (package != null) {
  for (final v in package.variants) {
    print('${v.id}  ep=${v.executionProvider} device=${v.device.name} '
          'size=${v.downloadSizeBytes} compatible=${v.isCompatible} '
          'reason=${v.incompatibilityReason}');
  }
}
```

`VariantConstraints` has exactly four fields; anything else the app tries to
add is ignored by the core:

| Field | Meaning |
|-|-|
| `maxDownloadBytes` | Skip variants whose selected files exceed this on the wire. |
| `allowedDevices` | Restrict placement. `null` and empty both mean "any". |
| `preferSmallest` | Tie-break on download size instead of the compatibility score. |
| `requireCached` | Only consider variants already on disk. Combined with `maxDownloadBytes: 0` this gives an "offline / no more downloads" mode. |

The declarative form above is the recommended path. For after-the-fact
orchestration — offering a picker UI, pre-provisioning several variants,
running an estimate before committing — the `ModelPackage` still exposes
`selectBestVariant`, `selectVariant`, `getVariant` and `estimateDownload`.
See [`docs/model-packages.md`](../../docs/model-packages.md) for the full
model.

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

- `FoundryLocal` — root object, one per process. Provides
  [`addModelSource`](lib/src/foundry_local.dart), the only supported way to
  hand the SDK a model on mobile.
- `Catalog` — inspect what is on the device (`listCachedModels`,
  `listModels`, cache size). Not an acquisition path — see
  [Model sources](#model-sources) above.
- `Model` — one shipped model (`load`, `unload`, `delete`, `package` for a
  nullable package view). Loading returns a typed `LoadResult` with `path`
  and `bytes`.
- `ModelPackage` — a model made of multiple per-device variants. Prefer
  setting `VariantConstraints` on the `ModelSource` so selection runs
  before any weights transfer; `selectBestVariant` / `selectVariant` /
  `getVariant` / `estimateDownload` remain for after-the-fact orchestration.
- `ChatSession` — `complete`, `completeStreaming`, `submitToolResults`,
  history export/restore.
  - `ChatCompletion.toolCalls` is `null` when the model asked for no tools,
    not an empty list — the distinction between "field absent" and "empty"
    is preserved. Each `ToolCall.argumentsJson` is the model's raw JSON
    string; parse it yourself when dispatching, so malformed arguments are
    the app's decision to handle.
  - `ChatCompletion.usage` is likewise nullable when the runtime did not
    report counters.
  - `ChatCompletion.finishReason` decodes to the [`FinishReason`] enum and
    falls back to `FinishReason.none` for unknown strings future runtimes
    may add.
- `AudioSession` — batch file transcription and streaming microphone input.
  Batch results are `TranscriptionResult` with typed
  `TranscriptionSegment`s.
- `EmbeddingSession` — single-batch text embeddings.
- `FlmTransport` — pluggable HTTP transport.

## License

MIT. See [LICENSE](LICENSE).
