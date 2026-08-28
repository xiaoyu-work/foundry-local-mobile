# Foundry Local Mobile — Android

Kotlin SDK for on-device inference with local ONNX Runtime GenAI (OGA) models.
The SDK is **path-only**: you supply a local model directory and the SDK loads
it directly through OGA. There is no catalog, no SDK-managed download, and no
transport layer. Runs through the same C++ core the iOS, Flutter and React
Native bindings sit on, exposed as `suspend` functions and `Flow`s.

- **`compileSdk`**: 35
- **`minSdk`**: 26 (Android 8.0)
- **ABIs**: `arm64-v8a`, `armeabi-v7a`, `x86_64`
- **Runtime**: ONNX Runtime GenAI, linked directly into the native core and
  loaded at process start via `System.loadLibrary`
- **Implemented**: text chat, streaming completions, multi-turn history, audio
  transcription, embeddings, multimodal inputs, and structured tool/reasoning
  deltas. The latter capabilities still need compatible-model device E2E coverage.

## Install

Add the AAR to your app module. Publishing to Maven Central is coordinated with
the release cycle; until then, build locally with:

```bash
./gradlew :bindings/android:foundry-local-mobile:assembleRelease
```

Then depend on the AAR:

```kotlin
dependencies {
    implementation("com.microsoft.ai.foundry.local:foundry-local-mobile:0.2.0")
}
```

The AAR bundles the mobile wrapper and its ONNX Runtime GenAI dependencies per ABI:

- `libfoundry_local_mobile.so` — the C++ core.
- `libfoundry_local_mobile_jni.so` — the JNI wrapper.
- `libonnxruntime-genai.so` and `libonnxruntime.so` — the inference runtime.

## Quickstart

```kotlin
val foundry = FoundryLocal.create(context, FoundryLocalConfig(appName = "my-app"))

val model = foundry.loadModel(
    path = "/data/models/qwen2.5-0.5b",
)

val chat = model.createChatSession()
chat.completeStreaming("What is the golden ratio?").collect { delta ->
    print(delta.text)
}
```

Every long-running operation returns a `Flow<Progress>` or a `Flow<Delta>`.
Both propagate collector-side cancellation into the core.

## Bring your own model

Bundle the model inside the APK, extract it to a real filesystem path, then
load it directly.

```kotlin
val modelDir = BundledAssets.extractToFilesDir(context, "models/qwen2.5-0.5b", "qwen2.5-0.5b")

val model = foundry.loadModel(
    path = modelDir.absolutePath,
    executionProvider = "QNNExecutionProvider",
)
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

## Lifecycle and network

`ProcessLifecycleOwner`, `ComponentCallbacks2` and
`ConnectivityManager.NetworkCallback` are wired to `flm_manager_notify_lifecycle`
automatically through an AndroidX Startup initializer. This lets the core
unload models under memory pressure and react to network transitions.

## Threading

Every callback the C ABI produces arrives on a core job-pool thread. The JNI
layer attaches those threads to the JVM with `AttachCurrentThreadAsDaemon`,
then dispatches through `NativeCallbacks` into Kotlin. Coroutine collectors
receive events on the dispatcher of their `CoroutineScope`, not on a core
thread.
