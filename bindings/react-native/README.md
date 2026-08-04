# @foundry-local/react-native

React Native binding for [Foundry Local Mobile](https://github.com/microsoft/foundry-local-mobile) —
on-device LLM inference from JavaScript, backed by ONNX Runtime.

## Status

| Platform | Status |
| --- | --- |
| Android | Wired. Wraps the `bindings/android/` Kotlin binding through a TurboModule. |
| iOS | **Not yet wired.** The Swift binding this module wraps is being written in parallel; the iOS TurboModule scaffold is in place but every native method rejects with a `notImplemented` `FoundryLocalError` at runtime. Do not use on iOS until the Swift binding lands and the iOS module is wired in a follow-up release. |

## Installation

```sh
npm install @foundry-local/react-native
```

**Requirements**

- React Native **≥ 0.73** with the **New Architecture** enabled (this package is a TurboModule; the legacy bridge is not supported).
- Android **minSdk 26** (arm64-v8a and armeabi-v7a). NDK build is handled by the wrapped Kotlin binding — no `externalNativeBuild` block in your app is required.
- Autolinking picks this package up automatically. If you have opted out of autolinking, register the module under `RNFoundryLocal`.

Codegen configuration is declared in this package's `package.json` (`codegenConfig`); no additional Gradle setup is needed in your app.

## Quickstart

```ts
import { FoundryLocal } from '@foundry-local/react-native';

const foundry = await FoundryLocal.create({ appName: 'my-app' });

// The catalog is for inspection, not acquisition. addModelSource is the only
// supply path on mobile — the desktop Foundry Local catalog publishes
// CUDA/DirectML/OpenVINO/x64 builds that a phone cannot execute.
const result = await foundry.addModelSource(
  {
    kind: 'remote',
    name: 'qwen2.5-0.5b',
    url: 'https://models.example.com/qwen2.5-0.5b/manifest.json',
  },
  (p) => console.log(`${p.percent}%`),
);

// `result.model` is a ready-to-use handle in the common case. See "The
// addModelSource result shape" below for when it can be null.
const model = result.model ?? (await foundry.catalog.getModel(result.name));
await model.load();

const chat = model.createChatSession();
for await (const delta of chat.completeStreaming('What is the golden ratio?')) {
  process.stdout.write(delta.text);
}
```

## API surface

The public exports are:

- `FoundryLocal` — entry point (`create`, `addModelSource`, `catalog`, `deviceProfile`, `updateSettings`, `setLogLevel`, `close`).
- `Catalog` — inspection only (`listModels`, `listCachedModels`, `getModel`, `getModelById`, `cacheSizeBytes`).
- `Model` / `ModelPackage` — a loaded model or an ONNX Runtime package with declarative variant policy.
- `ChatSession` — streaming (`completeStreaming`, `completeAllDeltas`) and non-streaming (`complete`, `submitToolResults`) completion.
- `AudioSession` — one-shot and streaming speech-to-text (`transcribe`, `transcribeStreaming`, `pushAudio`).
- `EmbeddingSession` — batch embeddings (`embed`).
- `FoundryLocalError` — errors, with `code`, `status`, `detailJson`, `isRetryable`.

Every long operation is a `Promise` or an `AsyncIterable`. Streams cancel through the standard `for await ... of` `break` path: breaking the loop calls `return()` on the iterator, which propagates through to `flm_job_cancel` on the native side. There is no separate `cancel()` method to call.

## Model sources

`addModelSource` is the acquisition API. Two source kinds are supported:

- `{ kind: 'bundled', path: '/absolute/path/inside/app' }` — a model shipped inside the APK. Set `copyIntoCache: true` when the path is temporary.
- `{ kind: 'remote', url: 'https://.../manifest.json', headers?: { Authorization: '…' } }` — a model hosted at a URL the app controls.

Common options on both kinds:

- `resume` (default `true`) — resume a partial download from disk.
- `verifyChecksums` (default `true`) — verify each file's SHA-256 after download.
- `constraints` — variant selection policy, applied against the manifest before any bytes transfer.

The variant policy vocabulary is exactly:

```ts
{
  maxDownloadBytes?: number;
  allowedDevices?: readonly ('cpu' | 'gpu' | 'npu')[];
  preferSmallest?: boolean;
  requireCached?: boolean;
}
```

Anything else you add is silently ignored by the core.

### The `addModelSource` result shape

`addModelSource` resolves to a `ModelSourceResult`, not directly to a `Model`:

```ts
interface ModelSourceResult {
  name: string;
  path: string;
  variantId: string | null;
  bytesDownloaded: number;
  bytesReused: number;
  wasCached: boolean;
  model: Model | null;
}
```

`model` is a ready-to-use handle in the common case — the core mints it inside the same job. It is `null` in the unexpected case where the download succeeded but the local scan did not pick the files up. The download itself succeeded either way; the null case is **not** an error. Fall back to `foundry.catalog.getModel(result.name)` if you specifically need a handle, or work from `result.path` directly:

```ts
const result = await foundry.addModelSource(source);
const model = result.model ?? (await foundry.catalog.getModel(result.name));
```

This deviates from the language-agnostic quickstart in the root project README, which shows `addModelSource` resolving to a `Model` directly. The deviation preserves the ABI's model-handle contract (a `uint64` that can legitimately be `FLM_INVALID_HANDLE`); fabricating a `Model` for that case or throwing would both be lossy. See the root README's TypeScript block if you want the two reconciled — the maintainers have offered to update the root README to match this shape.

## Streaming

Text streaming and every other streaming API return an `AsyncIterable`:

```ts
for await (const delta of chat.completeStreaming('...')) {
  process.stdout.write(delta.text);
}
```

`completeStreaming` filters out non-text deltas. Use `completeAllDeltas` when you need tool-call events, mid-generation usage frames, or the terminal `completed` delta:

```ts
for await (const delta of chat.completeAllDeltas({ messages: [...], tools: [...] })) {
  if (delta.kind === 'text') process.stdout.write(delta.text);
  else if (delta.kind === 'toolCall') runTool(delta.toolCall);
}
```

Cancellation propagates automatically. Breaking the `for await` loop calls the iterator's `return()`, which in turn calls `cancelSubscription` on the native side. A cancelled stream always terminates with an `error` event (status `cancelled`), so the underlying subscription is guaranteed to be cleaned up.

## Tool calling

`tool_calls[].arguments` is a JSON **string**, not a parsed object. A model may emit arguments that do not match the declared tool schema, and deciding whether that is fatal is the app's call. `tool_calls` and `usage` on `CompleteResult` are `null`, not empty, when there is nothing to report:

```ts
const result = await chat.complete({ messages, tools });

if (result.toolCalls) {
  const toolResults = result.toolCalls.map((call) => ({
    callId: call.callId,
    resultJson: JSON.stringify(await runTool(call.name, JSON.parse(call.argumentsJson))),
  }));
  for await (const delta of chat.submitToolResults(toolResults)) {
    // ...
  }
}
```

## Errors

Every SDK failure is a `FoundryLocalError` with:

- `code`: a `FoundryLocalErrorCode` string tag mirroring `flm_status`.
- `status`: the numeric ABI status.
- `message`: the human-readable message the core produced.
- `detailJson`: the raw detail payload, or `null`. Contains `{ retryable, context: { … } }`.
- `isRetryable`: convenience accessor for `detail.retryable`.

No bare `Error` reaches an app from the SDK.

## Architecture notes

- **Android**: this package's TurboModule wraps the Kotlin binding at `bindings/android/`. It does not re-bind the C ABI — every download, callback, transport, and lifecycle concern is handled by the Kotlin binding's existing OkHttp + WorkManager transport, which survives the app being backgrounded and applies the append-on-resume fix for partial downloads.
- **iOS**: the podspec depends on `React-Core`; every method rejects with `notImplemented` today. When the Swift binding lands the iOS module will wrap it the same way the Android module wraps Kotlin — see `ios/RNFoundryLocal.mm` for the scaffold and the TODO comment at the top.
- **Wire format**: everything richer than a primitive crosses the TurboModule boundary as a UTF-8 JSON string. The TypeScript layer parses/produces those strings, so the codegen'd spec stays small and the same JSON shape is used by the iOS module when it is wired.
- **Handles**: all native handles are opaque `number`s (slot ids into a per-module registry). The `0` slot is reserved as the invalid-handle sentinel.

## License

MIT
