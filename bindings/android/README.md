# Foundry Local Mobile — Android

Kotlin SDK for [Foundry Local](https://github.com/microsoft/Foundry-Local) on
Android. Runs on-device chat, embeddings, and speech-to-text through the same
C++ core the iOS, Flutter and React Native bindings sit on, exposed as
`suspend` functions and `Flow`s.

- **`compileSdk`**: 35
- **`minSdk`**: 26 (Android 8.0)
- **ABIs**: `arm64-v8a`, `armeabi-v7a`, `x86_64`
- **Runtime**: Foundry Local (ONNX Runtime GenAI), `dlopen`ed at first use

## Install

Add the AAR to your app module. Publishing to Maven Central is coordinated with
the release cycle; until then, build locally with:

```bash
./gradlew :bindings/android:foundry-local-mobile:assembleRelease
```

Then depend on the AAR:

```kotlin
dependencies {
    implementation("com.microsoft.ai.foundry.local:foundry-local-mobile:0.1.0")
    // Both are transitive api dependencies of the AAR — you can rely on the
    // versions the SDK pins, or override them if your app has stricter
    // requirements.
    // implementation("com.squareup.okhttp3:okhttp:4.12.0")
    // implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
}
```

The AAR bundles two native libraries per ABI slice:

- `libfoundry_local_mobile.so` — the C++ core.
- `libfoundry_local_mobile_jni.so` — the JNI wrapper.

The Foundry Local runtime (`libfoundry_local`) is **not** vendored — the SDK
`dlopen`s it at first use. Ship it inside your app or fetch it after first
launch and point the SDK at it via `NativeBridge.setRuntimeLibraryPath` before
your first `FoundryLocal.create`.

## Quickstart

```kotlin
// FoundryLocal.create is a suspend fun; call from a coroutine
// (lifecycleScope, viewModelScope, or your own).
val foundry = FoundryLocal.create(context, FoundryLocalConfig(appName = "my-app"))

// Point the SDK at your model: bundled in the app, or hosted on storage you control.
val result = foundry.addModelSource(
    ModelSource.Remote(
        name = "qwen2.5-0.5b",
        url = "https://models.example.com/qwen2.5-0.5b/manifest.json",
    )
) { progress -> println("${progress.percent}%") }

val model = result.requireModel()
model.load()

val chat = model.createChatSession()
chat.completeStreaming("What is the golden ratio?").collect { delta ->
    print(delta.text)
}
```

`addModelSource` returns a [`ModelSourceResult`](src/main/kotlin/com/microsoft/ai/foundry/local/mobile/Types.kt)
with the resolved `name`, `path`, download counters and — in the common case
— a ready-to-use `model`. `result.model` is `null` only when the download
succeeded but the catalog's local scan did not pick the files up.
[`requireModel()`](src/main/kotlin/com/microsoft/ai/foundry/local/mobile/Types.kt)
throws an actionable `IllegalStateException` that names both the source and
the on-disk path for that case; apps that want to handle it themselves —
falling back to `foundry.catalog.getModel(result.name)`, showing a
different UI — should read `result.model` directly instead.

Every long-running operation returns a `Flow<Progress>` or a `Flow<Delta>`.
Both propagate collector-side cancellation into the core — cancelling the
coroutine that collects a `completeStreaming` flow calls `flm_job_cancel`
under the covers and stops the inference, and the same for a download in
progress.

## Bring your own model

The SDK supports two ways of supplying a model in addition to the catalog. See
[`docs/model-sources.md`](../../docs/model-sources.md) for the full contract.

### Bundled inside the APK

```kotlin
// One-time extraction from assets to a real filesystem path. Idempotent —
// subsequent calls are no-ops until the assets change.
val modelDir = BundledAssets.extractToFilesDir(context, "models/phi-4-mini", "phi-4-mini")

val result = foundry.addModelSource(
    ModelSource.Bundled(name = "phi-4-mini", path = modelDir.absolutePath),
)
val model = result.model ?: foundry.catalog.getModel(result.name)
```

Make sure large model files are left uncompressed inside the APK, or
extraction goes through zlib and takes an order of magnitude longer:

```kotlin
android {
    androidResources {
        noCompress += listOf("onnx", "onnx_data", "bin")
    }
}
```

Android cannot load a model directly out of `assets/` — the files have no
filesystem path — so the SDK ships `BundledAssets` to copy them to
`filesDir` atomically (staging directory + rename) and idempotently (a
`.assets-manifest` hash file).

### Downloaded from storage you control

```kotlin
val result = foundry.addModelSource(
    ModelSource.Remote(
        name = "phi-4-mini",
        url = "https://models.example.com/phi-4-mini/manifest.json",
        headers = mapOf("Authorization" to "******"),
        // Both default to true. Turn `resume` off to force a fresh fetch,
        // and `verifyChecksums` off to skip the SHA-256 check on both the
        // reuse and post-download paths.
        resume = true,
        verifyChecksums = true,
    ),
) { progress ->
    println("Downloading ${progress.stage}: ${progress.percent}%")
}
val model = result.model ?: foundry.catalog.getModel(result.name)
```

The SDK sniffs the document, so both an ONNX Runtime **model package**
manifest and a flat file index work. When it is a package, only the variant
this device can run and the shared assets it references are downloaded —
never the variants a phone cannot run, which are routinely larger than the
one it can.

### Choosing a package variant

When the source resolves to a model package, express the cross-platform
policy declaratively on the source. The scoring runs against the manifest
before any bytes transfer, so a phone never pays for a QNN build it has no
NPU for:

```kotlin
val result = foundry.addModelSource(
    ModelSource.Remote(
        name = "qwen2.5-0.5b",
        url = "https://models.example.com/qwen2.5-0.5b/manifest.json",
        constraints = VariantConstraints(
            maxDownloadBytes = 800 * 1024 * 1024,
            allowedDevices = setOf(FlmDevice.NPU, FlmDevice.GPU, FlmDevice.CPU),
        ),
    ),
) { progress -> println("${progress.percent}%") }
val model = result.model ?: foundry.catalog.getModel(result.name)

// What was actually chosen, and what else the package offered.
val pkg = model.asPackage()
if (pkg != null) {
    for (v in pkg.variants.variants) {
        println("${v.id}  ep=${v.executionProvider}  device=${v.device}  " +
                "size=${v.downloadSizeBytes}  compatible=${v.isCompatible}  " +
                "reason=${v.incompatibilityReason}")
    }
}
```

`VariantConstraints` has exactly four fields: `maxDownloadBytes`,
`allowedDevices`, `preferSmallest` (tie-break on size instead of the
compatibility score), and `requireCached` (only consider variants already on
disk — useful for an offline path). Anything else is silently ignored by
the core.

**On acquisition.** `addModelSource` is the only supply path — the SDK does
not fetch from a catalog. The Foundry Local catalog publishes desktop builds
(CUDA, DirectML, OpenVINO, x64), which are gigabytes of weights a phone
cannot execute, so the catalog only serves as a name/metadata registry for
models the app has already registered. `Model.load()` never downloads on
demand: calling it on a model whose files are not on the device throws
`NotImplementedException` pointing back at `addModelSource`.

## HTTP transport

The core plans downloads but does not perform them. Requests are handed to a
transport implementation the binding installs, and this Android binding ships
two:

### `OkHttpTransport` (default)

Fast, foreground. Handles ranged resume, in-memory delivery for small
documents (catalog listings, manifest sniffs), and reports every request's
completion in a `finally` block — the core blocks a job thread on that
report, so a missed one is a permanent hang.

Install with a custom OkHttp client for certificate pinning, custom auth, or
a proxy:

```kotlin
val transport = OkHttpTransport(
    client = OkHttpClient.Builder()
        .addInterceptor(BearerTokenInterceptor(::currentAccessToken))
        .certificatePinner(pinner)
        .build(),
)
// create is a suspend fun; call from a coroutine.
val foundry = FoundryLocal.create(context, cfg, transport = transport)
```

### `WorkManagerTransport` (background-safe)

Large downloads must survive the app being backgrounded, and the only reliable
way to do that on Android is [WorkManager](https://developer.android.com/topic/libraries/architecture/workmanager)
or DownloadManager, both of which hand the transfer to a system daemon. This
transport routes disk transfers through WorkManager and keeps small in-memory
requests on OkHttp (WorkManager scheduling latency is unacceptable for a
manifest sniff).

```kotlin
// create is a suspend fun; call from a coroutine.
val foundry = FoundryLocal.create(
    context,
    cfg,
    transport = WorkManagerTransport(context),
)
```

Trade-off: WorkManager adds seconds of latency before a job starts and can
defer the transfer until the device is on unmetered Wi-Fi. Both are usually
what the user wants for a 3 GB download; both are wrong for a 4 KB
manifest — hence the split.

### Custom transports

Implement `HttpTransport.send` / `.cancel` and pass an instance to
`FoundryLocal.create(transport = ...)`. Respect the contract:

- `send` returns immediately. Do the work on your own dispatcher.
- Return 0 to indicate acceptance; return non-zero to fail fast.
- Once you've returned 0, `reporter.reportComplete` **must** fire exactly once
  for the request — including cancelled and failed ones.
- When `offset > 0`, send `Range: bytes=<offset>-` and append to the file at
  that offset rather than truncating.
- When `destinationPath == null`, deliver the body with `reporter.reportBody`.

## Lifecycle and network

`ProcessLifecycleOwner`, `ComponentCallbacks2` and
`ConnectivityManager.NetworkCallback` are wired to `flm_manager_notify_lifecycle`
automatically through an AndroidX Startup initializer. This is what lets the
core unload models under memory pressure and pause downloads on a metered
link. Apps that want to disable auto-registration can remove the initializer
in their manifest.

## Threading

Every callback the C ABI produces arrives on a core job-pool thread. The JNI
layer attaches those threads to the JVM with `AttachCurrentThreadAsDaemon`
(so a lingering attach cannot block JVM exit), then dispatches through
`NativeCallbacks` and `TransportDispatcher` into Kotlin. Coroutine collectors
receive events on the dispatcher of their `CoroutineScope`, not on a core
thread. You never have to marshal to the main thread yourself.

## R8 / ProGuard

The AAR ships `consumer-rules.pro` that keeps the classes and methods JNI
looks up by name. If your app rewrites merged rules aggressively (uncommon),
make sure those keeps survive.

## What is not here

- **Tests.** By design.
- **A bundled runtime.** The Foundry Local shared library is loaded at
  runtime, so the AAR stays small and apps can ship whichever runtime
  build matches their target hardware.
- **A blocking API.** The C ABI exposes `flm_job_wait` for CLI use; the
  Kotlin API deliberately does not — no code path in this binding can stall
  the caller's thread.
