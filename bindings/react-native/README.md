# @foundry-local/react-native

React Native binding for [Foundry Local Mobile](https://github.com/microsoft/foundry-local-mobile) —
on-device LLM inference from JavaScript, backed by ONNX Runtime.

## Status

| Platform | Status |
| --- | --- |
| Android | Self-contained AAR. Wraps the Kotlin SDK through a TurboModule. |
| iOS | Self-contained Swift sources plus core and ONNX Runtime GenAI XCFrameworks. Physical-device E2E remains pending. |

The published npm package contains the native Android and Apple artifacts it
needs; consuming apps do not need a checkout of this repository.

## Installation

```bash
npm install @foundry-local/react-native
```

**Requirements**

- React Native **≥ 0.73** with the **New Architecture** enabled (this package is a TurboModule; the legacy bridge is not supported).
- Android **minSdk 26** (arm64-v8a, armeabi-v7a, and x86_64). The package contains the native AAR; no `externalNativeBuild` block is required in your app.
- iOS **15.0+** (the Swift binding uses `AsyncThrowingStream`). CocoaPods links the two bundled XCFrameworks automatically.
- Autolinking picks this package up automatically. If you have opted out of autolinking, register the module under `RNFoundryLocal`.

Codegen configuration is declared in this package's `package.json` (`codegenConfig`); no additional Gradle setup is needed in your app.

## Quickstart

```ts
import { FoundryLocal } from '@foundry-local/react-native';

const foundry = await FoundryLocal.create({ appName: 'my-app' });

// Load a model directly from a local directory path.
const model = await foundry.loadModel('/path/to/models/qwen2.5-0.5b');

const chat = model.createChatSession();
for await (const delta of chat.completeStreaming('What is the golden ratio?')) {
  process.stdout.write(delta.text);
}
```

## API surface

The public exports are:

- `FoundryLocal` — entry point (`create`, `loadModel`, `deviceProfile`, `updateSettings`, `setLogLevel`, `close`).
- `Model` — a loaded model handle.
- `ChatSession` — streaming (`completeStreaming`, `completeAllDeltas`) and non-streaming (`complete`, `submitToolResults`) completion, including multimodal input and structured tool/reasoning deltas.
- `AudioSession` — one-shot and streaming speech-to-text (`transcribe`, `transcribeStreaming`, `pushAudio`).
- `EmbeddingSession` — batch embeddings (`embed`).
- `FoundryLocalError` — errors, with `code`, `status`, `detailJson`, `isRetryable`.

Every long operation is a `Promise` or an `AsyncIterable`. Streams cancel through the standard `for await ... of` `break` path: breaking the loop calls `return()` on the iterator, which propagates through to `flm_job_cancel` on the native side. There is no separate `cancel()` method to call.

## Loading models

Load a model directly from a local directory path:

```ts
const model = await foundry.loadModel('/absolute/path/to/model', {
  executionProvider: 'QNNExecutionProvider',
  providerOptions: { backend_path: 'libQnnHtp.so' },
});
```

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

> **Not yet complete.** The native core does not currently detect or parse
> model-emitted tool calls: `result.toolCalls` is always `null` and no
> `toolCall` delta is emitted, even when `tools` are supplied. The shape below
> documents the intended API once structured tool-call parsing lands.

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

- **Android**: this package's TurboModule wraps the bundled Kotlin AAR. It does not re-bind the C ABI; the module forwards JSON payloads and registry slot ids to the underlying binding.
- **iOS**: this package's TurboModule compiles its bundled Swift SDK sources. `ios/RNFoundryLocalCore.swift` owns the handle registries and subscription table; `ios/RNFoundryLocal.mm` is a thin Objective-C++ `RCTEventEmitter` that exports the codegen'd selectors and forwards to Swift. Streaming maps `AsyncThrowingStream` to the same `FoundryLocal:*` event names the Android module uses, so the shared JS async-iterator layer is platform-agnostic.
- **Wire format**: everything richer than a primitive crosses the TurboModule boundary as a UTF-8 JSON string. The TypeScript layer parses/produces those strings, so the codegen'd spec stays small and the same JSON shape is used by iOS and Android.
- **Handles**: all native handles are opaque `number`s (slot ids into a per-module registry). The `0` slot is reserved as the invalid-handle sentinel.

## License

MIT
