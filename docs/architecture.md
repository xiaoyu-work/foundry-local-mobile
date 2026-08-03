# Architecture

Foundry Local Mobile is a layered SDK. Each layer has exactly one job, and every
platform binding shares the layers below it — there is no per-platform reimplementation
of catalog logic, download logic, or model-package variant selection.

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
│  flm_* — flat, FFI-friendly C ABI                                          │  Layer 2
│  handles · async jobs · callbacks · JSON metadata                          │  ABI
├───────────────────────────────────────────────────────────────────────────┤
│  Mobile core (C++20)                                                      │  Layer 1
│  job pool · model packages · device profile · lifecycle · storage         │  core
├───────────────────────────────────────────────────────────────────────────┤
│  Foundry Local core (flApi function tables, libfoundry_local)             │  Layer 0
│  catalog · download · ORT GenAI inference · EP registration               │  upstream
└───────────────────────────────────────────────────────────────────────────┘
```

## Layer 0 — Foundry Local core (upstream, unmodified)

The upstream [Foundry Local](https://github.com/microsoft/Foundry-Local) C++ SDK
(`sdk_v2/cpp`) provides model catalog access, downloads, ONNX Runtime GenAI inference and
EP registration. It exposes a versioned C ABI built from **structs of function pointers**
(`flApi`, `flCatalogApi`, `flModelApi`, `flInferenceApi`, …) reached through three exported
symbols.

We consume it as a prebuilt shared library plus headers. We never fork it. Upstream ABI
additions are append-only, so a newer runtime keeps working with an older binding.

## Layer 1 — Mobile core (`core/`)

A C++20 library that adds what mobile apps need and desktop apps do not:

| Concern | What the core does |
|---|---|
| **Threading** | A job pool. Every long operation (download, load, inference) runs off the caller thread and reports through callbacks, because UI threads on Android/iOS must never block. |
| **Model packages** | Parses package manifests, enumerates variants, scores them against the device, and drives selective download. See [model-packages.md](model-packages.md). |
| **Device profile** | Detects SoC, NPU availability (QNN on Android, ANE on Apple), total/available RAM, thermal state, and turns that into an EP preference order. |
| **Storage** | Resolves app-sandbox cache directories, applies platform "do not back up" / "cache evictable" attributes, and reports disk headroom before a download starts. |
| **Lifecycle** | Foreground/background transitions and memory-pressure notifications, mapped to model unload/reload and inference pause/cancel. |
| **Error mapping** | Turns `flStatus*` into a stable, binding-friendly error code + message + JSON detail. |

## Layer 2 — The `flm_*` C ABI (`core/include/foundry_local_mobile/`)

This is the contract every binding compiles against. It deliberately differs from the
upstream ABI in four ways, each driven by what FFI systems can express:

1. **Flat exported functions, not function tables.** `dart:ffi`, JNI and Swift C interop
   all bind exported symbols trivially; walking nested structs of function pointers from
   Dart or Swift is error-prone boilerplate. The core does that walk once, in C++.

2. **Handles are `uint64_t`, not pointers.** A 64-bit integer handle survives Dart
   isolates, JNI `long` fields and Swift value types without pointer-provenance games, and
   lets the core validate liveness instead of crashing on a stale pointer. A handle table
   turns use-after-free into a clean `FLM_ERROR_INVALID_HANDLE`.

3. **Async by default, via job handles.** Every operation that can take more than a few
   milliseconds has an `flm_*_async` form that returns immediately with an
   `flm_job` handle. Completion, progress and streaming arrive on callbacks. Bindings map
   jobs onto coroutines, `async/await`, `Future`s and `Promise`s. `flm_job_cancel` works
   for all of them uniformly.

4. **JSON for metadata, raw C for the hot path.** Model info, package manifests, variant
   descriptors and device profiles cross the boundary as UTF-8 JSON — marshalling ~20
   struct fields through four different FFI systems is a bug farm, and this data is read
   once. Token deltas cross as plain `const char*` in a callback, because that *is* the
   hot path and must not allocate a JSON document per token.

The ABI is versioned with `FLM_API_VERSION`; every struct carries a `version` field and
grows append-only, mirroring the upstream convention.

## Layer 3 — Platform bridges

- **Android** — a small C++ JNI layer. Callbacks arrive on core job-pool threads, so the
  bridge attaches the thread to the JVM and posts results to the caller's coroutine
  context. Native libraries ship in the AAR under `jniLibs/<abi>/`.
- **iOS** — Swift talks to the C ABI directly through a module map; a thin Objective-C++
  shim exists only for `os_signpost` instrumentation and lifecycle notifications. Ships as
  an XCFramework (device + simulator slices).
- **Flutter** — Dart binds `flm_*` through `dart:ffi` with `NativeCallable.listener`, so
  native callbacks land on the Dart isolate without a platform-channel hop. Method
  channels are used only for things Dart cannot ask the OS itself (sandbox paths,
  memory-pressure notifications).
- **React Native** — a TurboModule that **reuses the Kotlin and Swift bindings** rather
  than binding the C ABI a third time. One less native surface to maintain, and RN apps
  get the same behaviour as native apps. Streaming uses the JSI event emitter.

## Layer 4 — Idiomatic APIs

Each binding exposes the same object model with platform-native ergonomics:

```
FoundryLocal ──▶ Catalog ──▶ Model / ModelPackage ──▶ ModelVariant
                                    │
                                    ├──▶ ChatSession   (streaming text, tools, history)
                                    ├──▶ AudioSession  (speech-to-text)
                                    └──▶ EmbeddingSession
```

The names, argument order and semantics are kept aligned across the four languages so
documentation and samples translate directly. Where a platform has a strong idiom
(`Flow`, `AsyncSequence`, `Stream`, async iterator) the binding uses it rather than
inventing a callback API.

## Design principles

1. **One implementation of every decision.** Variant scoring, cache layout and retry
   policy live in the core. A binding that adds its own policy is a bug.
2. **Never block a UI thread.** No blocking call is exposed in any binding's public API.
3. **Fail loud at the boundary, not deep inside.** Handles and struct versions are
   validated on entry to the ABI so binding bugs surface as errors, not crashes.
4. **The app owns the download policy.** The SDK reports sizes, variants and device
   compatibility; it never silently downloads gigabytes on a metered network.
5. **Append-only ABI.** New fields go at the end of structs; new functions go at the end
   of the header. A binding built against `FLM_API_VERSION` N runs against runtime N+1.
