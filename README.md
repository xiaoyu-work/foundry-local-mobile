<div align="center">

# Foundry Local Mobile

**Ship on-device AI inside your mobile app — iOS, Android, Flutter and React Native.**

</div>

Foundry Local Mobile brings the [Foundry Local](https://github.com/microsoft/Foundry-Local)
on-device AI runtime to mobile platforms. It wraps the Foundry Local C++ core in a single,
FFI-friendly C ABI and layers idiomatic SDKs on top of it, so the same runtime, the same
model catalog, and the same **ONNX Runtime Model Packages** are available from Kotlin,
Swift, Dart and TypeScript.

User data never leaves the device, responses start immediately with zero network latency,
and your app works offline. No per-token costs, no API keys, no backend to maintain.

## Supported targets

| Target | Package | Language surface |
|---|---|---|
| **Android** | `com.microsoft.ai.foundry.local:foundry-local-mobile` (AAR) | Kotlin — suspend functions + `Flow` streaming |
| **iOS** | `FoundryLocalMobile` (Swift Package / XCFramework) | Swift — `async/await` + `AsyncThrowingStream` |
| **Flutter** | `foundry_local_mobile` (pub) | Dart — FFI, `Future` + `Stream` |
| **React Native** | `@foundry-local/react-native` (npm) | TypeScript — `Promise` + async iterators |

All four bindings sit on the **same** native core, so behaviour, model cache layout and
model-package selection are identical across platforms.

### Maturity

The bindings are not equally proven, and it would be misleading to present them as if they
were. What each one has actually been through:

| Target | Compiled | Verified on device |
|---|---|---|
| **Core (C++ / C ABI)** | Yes — Linux and Android NDK (`arm64-v8a`, `armeabi-v7a`, `x86_64`) | No |
| **Android** | Yes — AAR builds; JNI exports reconciled against Kotlin declarations in CI | Not yet |
| **iOS** | Not yet — no Swift toolchain has been run against it | No |
| **Flutter** | Partly — `flutter analyze` is clean and the C trampoline compiles; the plugin has never been built into an app | No |
| **React Native** | In progress | No |

"Compiled" is a real guarantee and a narrow one: the Android binding's native symbols are
checked against its Kotlin `external fun` declarations at build time, which turns what
would otherwise be an `UnsatisfiedLinkError` on a user's phone into a build failure. It
says nothing about whether the code behaves correctly once it runs. Treat the unchecked
rows as unproven rather than broken, and please report what you find.

## Why a separate mobile SDK?

Mobile is not just "desktop with a smaller screen". This repo exists because on-device AI
on phones has constraints that the desktop SDK does not model:

- **Sandboxed storage.** Model caches must live in app-private directories that the OS may
  evict. The SDK resolves and manages those paths for you.
- **Metered networks and multi-GB models.** Downloads must be resumable, cancellable,
  Wi-Fi-aware, and must fetch *only* the model-package variants the device can actually run.
- **Hard memory ceilings.** iOS jetsam and Android low-memory kills mean models must unload
  on memory pressure and reload transparently.
- **App lifecycle.** Inference has to pause and resume as the app moves between foreground
  and background.
- **Heterogeneous NPUs.** Qualcomm QNN, Apple Neural Engine and CPU fallbacks are selected
  per-device from model-package variant metadata.

## Native ONNX Runtime Model Package support

Model packages are a first-class concept in this SDK, not an implementation detail.
A package bundles multiple build **variants** of the same model — one per execution
provider / device / compatibility string — behind a single manifest.

Your app can inspect the variants of a package and decide what to download, which is
exactly what a cross-platform app needs:

Point the SDK at a package manifest and it scores this device against every variant,
then fetches only the one that device can run:

```dart
final model = await foundry.addModelSource(
  const ModelSource.remote(
    name: 'qwen2.5-0.5b',
    url: 'https://models.example.com/qwen2.5-0.5b/manifest.json',
    // Your cross-platform policy, applied before anything is transferred.
    constraints: VariantConstraints(
      maxDownloadBytes: 800 * 1024 * 1024,
      allowedDevices: [FlmDevice.npu, FlmDevice.gpu, FlmDevice.cpu],
    ),
  ),
  onProgress: (p) => print('${p.percent}%'),
);

// What was actually chosen, and what else the package offered.
for (final v in model.package!.variants) {
  print('${v.id}  ep=${v.executionProvider} device=${v.device} '
        'size=${v.downloadSizeBytes} compatible=${v.isCompatible} '
        'reason=${v.incompatibilityReason}');
}
```

The scoring runs against the manifest before any weights move, so a phone never spends
bytes on a QNN build it has no NPU for, or an iOS-only CoreML build. Only the selected
variant's files plus the shared assets it references are fetched — in a package whose
variants share a tokenizer, that shared file is downloaded once.

See [`docs/model-packages.md`](docs/model-packages.md) for the full model.

## Bring your own model

Models do not have to come from a catalog. Ship one inside your app, or host it on storage
you control and give the SDK the URL and credentials:

```kotlin
// Bundled in the app — works offline from first launch.
val local = foundry.addModelSource(
    ModelSource.Bundled(name = "phi-4-mini", path = extractedModelDir.absolutePath)
).model

// Or downloaded from your own storage, with your own credentials.
val remote = foundry.addModelSource(
    ModelSource.Remote(
        name = "phi-4-mini",
        url = "https://models.example.com/phi-4-mini/manifest.json",
        headers = mapOf("Authorization" to "Bearer $token"),
    )
).model
```

When the URL serves a model package, the SDK scores this device against the variants and
downloads only the one it can run. Downloads resume across restarts and every file is
verified against its manifest digest. See
[`docs/model-sources.md`](docs/model-sources.md).

## Quickstart

<details open>
<summary><strong>Kotlin (Android)</strong></summary>

```kotlin
val foundry = FoundryLocal.create(context, FoundryLocalConfig(appName = "my-app"))

// Point the SDK at your model: bundled in the app, or hosted on storage you control.
val added = foundry.addModelSource(
    ModelSource.Remote(
        name = "qwen2.5-0.5b",
        url = "https://models.example.com/qwen2.5-0.5b/manifest.json",
    )
) { progress -> println("${progress.percent}%") }

// Acquiring a model hands one straight back. `model` is null only in the rare case
// where the files landed but the local scan missed them, so fall back to the catalog.
val model = added.model ?: foundry.catalog.getModel(added.name)

model.load()

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

// Point the SDK at your model: bundled in the app, or hosted on storage you control.
let source = ModelSource.remote(
    name: "qwen2.5-0.5b",
    url: URL(string: "https://models.example.com/qwen2.5-0.5b/manifest.json")!
)
let model = try await foundry.addModelSource(source) { progress in
    print("\(progress.percent)%")
}

try await model.load()

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

// Point the SDK at your model: bundled in the app, or hosted on storage you control.
final model = await foundry.addModelSource(
  const ModelSource.remote(
    name: 'qwen2.5-0.5b',
    url: 'https://models.example.com/qwen2.5-0.5b/manifest.json',
  ),
  onProgress: (p) => print('${p.percent}%'),
);

await model.load();

final chat = model.createChatSession();
await for (final delta in chat.completeStreaming('What is the golden ratio?')) {
  stdout.write(delta.text);
}
```

</details>

<details open>
<summary><strong>TypeScript (React Native)</strong></summary>

```ts
const foundry = await FoundryLocal.create({ appName: 'my-app' });

// Point the SDK at your model: bundled in the app, or hosted on storage you control.
const model = await foundry.addModelSource(
  { kind: 'remote', name: 'qwen2.5-0.5b',
    url: 'https://models.example.com/qwen2.5-0.5b/manifest.json' },
  (p) => console.log(`${p.percent}%`),
);

await model.load();

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
  src/                Implementation over the Foundry Local flApi function tables
bindings/
  android/            Gradle library: JNI bridge + Kotlin API
  ios/                Swift Package: C interop + Swift API
  flutter/            Dart FFI plugin
  react-native/       TurboModule (Kotlin + Swift) + TypeScript API
samples/              Runnable sample apps for each target
scripts/              Cross-compilation and packaging scripts
docs/                 Architecture, model packages, platform notes
```

## Documentation

- [Architecture](docs/architecture.md) — how the layers fit together and why
- [Model sources](docs/model-sources.md) — bundling a model, or downloading from your own storage
- [Model packages](docs/model-packages.md) — variants, selection, selective download
- [Building from source](docs/building.md) — NDK / Xcode toolchains and packaging
- [Platform support](docs/platform-support.md) — OS versions, ABIs, accelerators

## License

MIT — see [LICENSE](LICENSE). Models downloaded through Foundry Local are subject to their
own license terms.
