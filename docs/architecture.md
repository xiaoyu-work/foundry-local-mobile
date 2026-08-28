# Architecture

Foundry Local Mobile is a layered SDK. Each layer has exactly one job, and every
platform binding shares the layers below it — there is no per-platform reimplementation
of model loading or inference.

```
┌───────────────────────────────────────────────────────────────────────────┐
│  App code                                                                 │
├──────────────┬──────────────┬───────────────┬─────────────────────────────┤
│  Kotlin API  │  Swift API   │  Dart API     │  TypeScript API             │  Layer 4
│  (coroutines │  (async/await│  (Future /    │  (Promise / async iterator) │  idiomatic
│   + Flow)    │   + AsyncSeq)│   Stream)     │                             │
├──────────────┼──────────────┼───────────────┼─────────────────────────────┤
│  JNI bridge  │  Swift C     │  dart:ffi     │  TurboModule (reuses the    │  Layer 3
│  (C++)       │  interop     │  (direct)     │  Kotlin + Swift bindings)   │  binding
├──────────────┴──────────────┴───────────────┴─────────────────────────────┤
│  flm_* — flat, FFI-friendly C ABI (version 2)                              │  Layer 2
│  handles · async jobs · callbacks · JSON metadata                          │  ABI
├───────────────────────────────────────────────────────────────────────────┤
│  Mobile core (C++20)                                                      │  Layer 1
│  job pool · device profile · lifecycle · error mapping                    │  core
├───────────────────────────────────────────────────────────────────────────┤
│  ONNX Runtime GenAI C API (ort_genai_c.h) — linked directly                │  Layer 0
│  model/config loading · tokenizer · generator loop · EP registration      │  runtime
└───────────────────────────────────────────────────────────────────────────┘
```

There used to be a fifth layer here: the Microsoft [Foundry Local](https://github.com/microsoft/Foundry-Local)
desktop SDK, consumed as a prebuilt runtime with its own catalog, downloader and
`flApi`/`flCatalogApi`/`flModelApi` function-table ABI. That dependency has been removed
completely. The core now links directly against the
[ONNX Runtime GenAI](https://github.com/microsoft/onnxruntime-genai) (OGA) C API at build
time — no dynamic discovery, no version-table walk, no upstream catalog or download
logic to carry along.

## Layer 0 — ONNX Runtime GenAI (linked, not wrapped)

The core builds against `onnxruntime-genai` either as a source subdirectory (staged by
`scripts/fetch_onnxruntime_genai.sh`, pinned to commit
[`9d336e4`](https://github.com/microsoft/onnxruntime-genai/commit/9d336e4db4e49eeceda909517b882c0d73cc6c86))
or as an installed CMake package. `core/src/runtime.cc` is a thin RAII wrapper around
`OgaModel`, `OgaTokenizer`, `OgaGenerator` and friends — it owns process-wide `OgaShutdown`
lifecycle and turns `OgaResult*` errors into `flm::Error`. There is no `dlopen`, no
runtime-supplied function table, and `flm_is_runtime_available()` is unconditionally true
once the library is linked.

## Layer 1 — Mobile core (`core/`)

A C++20 library that adds what mobile apps need and desktop apps do not:

| Concern | What the core does |
|---|---|
| **Threading** | A job pool. Every long operation (model load, inference) runs off the caller thread and reports through callbacks, because UI threads on Android/iOS must never block. |
| **Model loading** | Validates a caller-supplied local directory (flat OGA model or OGA package), builds an `OgaConfig`/`OgaModel`/`OgaTokenizer`, and enforces a memory budget before loading so the OS does not kill the process mid-load. |
| **Device profile** | Detects SoC, NPU availability (QNN on Android, ANE on Apple), total/available RAM, and thermal state, and turns that into an execution-provider preference. |
| **Lifecycle** | Foreground/background transitions and memory-pressure notifications, mapped to model unload/reload and inference pause/cancel. |
| **Error mapping** | Turns `OgaResult*` and internal failures into a stable, binding-friendly error code + message + JSON detail. |

There is no catalog, no downloader, no transport layer and no SDK-managed cache anywhere
in this layer. Getting model files onto the device is entirely the app's job.

## Layer 2 — The `flm_*` C ABI (`core/include/foundry_local_mobile/`)

This is the contract every binding compiles against (`FLM_API_VERSION` 2, library version
0.2.0). It is deliberately flat, for what FFI systems can express cheaply:

1. **Flat exported functions, not function tables.** `dart:ffi`, JNI and Swift C interop
   all bind exported symbols trivially.

2. **Handles are `uint64_t`, not pointers.** A 64-bit integer handle survives Dart
   isolates, JNI `long` fields and Swift value types without pointer-provenance games, and
   lets the core validate liveness instead of crashing on a stale pointer. A handle table
   turns use-after-free into a clean `FLM_ERROR_INVALID_HANDLE`.

3. **Async by default, via job handles.** Every operation that can take more than a few
   milliseconds has an `flm_*_async` form that returns immediately with an
   `flm_job` handle. Completion, progress and streaming arrive on callbacks. Bindings map
   jobs onto coroutines, `async/await`, `Future`s and `Promise`s.

4. **JSON for metadata, raw C for the hot path.** Model info and device profiles cross the
   boundary as UTF-8 JSON. Token deltas cross as plain `const char*` in a callback, because
   that *is* the hot path and must not allocate a JSON document per token.

The ABI is versioned with `FLM_API_VERSION`; every struct carries a `version` field and
grows append-only.

### What the ABI does and does not cover today

Implemented and exercised: `flm_manager_load_model_async` / `flm_model_load_async` /
`flm_model_unload_async`, `flm_session_create` for chat, `flm_session_complete_async`
(streaming text deltas), and the session history calls (`flm_session_get_turn_count`,
`flm_session_undo_turns`, `flm_session_clear_history`,
`flm_session_export_history_json` / `flm_session_restore_history_json`).

Present in the header but **not implemented** in the current backend —
`flm_session_transcribe_async`, `flm_session_push_audio`, and `flm_session_embed_async`
all throw `FLM_ERROR_NOT_IMPLEMENTED`. `flm_session_submit_tool_results_async` runs, but
the core does not parse a model's raw output into structured tool calls, so
`FLM_FINISH_TOOL_CALLS` is never produced and no `FLM_DELTA_TOOL_CALL` event is emitted
today.

## Layer 3 — Platform bridges

- **Android** — a small C++ JNI layer. Callbacks arrive on core job-pool threads, so the
  bridge attaches the thread to the JVM and posts results to the caller's coroutine
  context. Native libraries ship in the AAR under `jniLibs/<abi>/`: the core, the JNI
  wrapper, and `libonnxruntime-genai.so` + `libonnxruntime.so`.
- **iOS** — Swift talks to the C ABI directly through a module map; a thin Objective-C++
  shim exists only for lifecycle notifications. Ships as an XCFramework (device +
  simulator slices).
- **Flutter** — Dart binds `flm_*` through `dart:ffi` with `NativeCallable.listener`, so
  native callbacks land on the Dart isolate without a platform-channel hop. Method
  channels are used only for things Dart cannot ask the OS itself (lifecycle,
  memory-pressure notifications).
- **React Native** — a TurboModule that **reuses the Kotlin and Swift bindings** rather
  than binding the C ABI a third time. Streaming uses the JSI event emitter.

## Layer 4 — Idiomatic APIs

Each binding exposes the same object model with platform-native ergonomics:

```
FoundryLocal ──▶ Model (loaded from a caller-owned path)
                    │
                    ├──▶ ChatSession   (streaming text, history — implemented)
                    ├──▶ AudioSession  (speech-to-text — not implemented)
                    └──▶ EmbeddingSession (not implemented)
```

The names, argument order and semantics are kept aligned across the four languages so
documentation and samples translate directly. Where a platform has a strong idiom
(`Flow`, `AsyncSequence`, `Stream`, async iterator) the binding uses it rather than
inventing a callback API.

## Design principles

1. **One implementation of every decision.** Device-profile scoring, memory budgeting and
   error mapping live in the core. A binding that adds its own policy is a bug.
2. **Never block a UI thread.** No blocking call is exposed in any binding's public API.
3. **Fail loud at the boundary, not deep inside.** Handles and struct versions are
   validated on entry to the ABI so binding bugs surface as errors, not crashes.
4. **The app owns model acquisition.** The SDK never reaches out to the network on its
   own; it only loads what is already on disk.
5. **Append-only ABI.** New fields go at the end of structs; new functions go at the end
   of the header. A binding built against `FLM_API_VERSION` N runs against runtime N+1.
