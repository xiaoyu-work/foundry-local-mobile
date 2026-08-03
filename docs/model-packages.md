# Model packages

Foundry Local Mobile treats [ONNX Runtime model packages][mp-spec] as a first-class
concept. This page explains what they are, why they matter more on mobile than anywhere
else, and how an app drives variant selection across platforms.

## What a package is

A model package is a directory with a top-level `manifest.json` that bundles multiple
build **variants** of the same model behind one entry, plus content-addressed **shared
assets** that variants reference instead of duplicating.

```
qwen2.5-0.5b/
├── manifest.json
├── variants/
│   ├── qnn-npu/          genai_config.json + compiled QNN context binaries
│   ├── coreml-ane/       genai_config.json + CoreML artifacts
│   └── cpu/              genai_config.json + int4 CPU graph
└── shared_assets/
    └── sha256-9f86d081.../    tokenizer + weights referenced by several variants
```

Each variant declares an execution provider (`ep`), a `device`, and an EP-defined opaque
`compatibility_string`. At load time the runtime scores the variants against the local
hardware and picks the highest-scoring compatible one. Variants reference shared assets
with `sha256:<hex>` strings that the runtime resolves to real paths.

A directory is a package when it has a top-level `manifest.json` and **no** top-level
`genai_config.json`.

## Why this matters more on mobile

On a desktop, downloading every variant of a package is wasteful. On a phone it is
unacceptable: the variants that a device cannot run are frequently *larger* than the one
it can, mobile storage is scarce, and the connection is often metered.

The mobile SDK therefore never downloads a whole package. It downloads **one variant plus
the shared assets that variant references**. Everything else stays in the cloud.

The mobile device landscape also makes the "one entry, many variants" model much more
valuable than on desktop:

| Device class | Selected variant |
|---|---|
| Snapdragon 8 Gen 2/3 Android | QNN / NPU — Hexagon NPU, compiled context binary |
| Other Android arm64 | CPU int4, or GPU where the driver is trustworthy |
| iPhone / iPad (A14+) | CoreML / ANE |
| Older iPhone, or thermally limited | CPU int4 |

A cross-platform app publishes **one** model alias and gets the right binary everywhere.

## The API

Every binding exposes the same three-step model: **inspect → choose → download**.

### Inspect

```kotlin
val pkg = foundry.catalog.getModel("qwen2.5-0.5b")

if (pkg.isPackage) {
    pkg.variants.forEach { v ->
        println("${v.id} ep=${v.executionProvider} device=${v.device} " +
                "download=${v.downloadSizeBytes} compatible=${v.isCompatible} " +
                "score=${v.compatibilityScore}")
    }
}
```

`downloadSizeBytes` is the number of bytes that would actually be transferred — shared
assets already on disk are excluded, so it changes as the cache fills.
`compatibilityScore` is the EP's own score for this device; higher wins.

### Choose

Either let the SDK decide:

```kotlin
val chosen = pkg.selectBestVariant(
    VariantConstraints(
        maxDownloadBytes = 800L * 1024 * 1024,
        allowedDevices = setOf(FlmDevice.NPU, FlmDevice.CPU),
    )
)
```

Or apply your own cross-platform policy, which is the point of exposing the metadata:

```dart
// A Flutter app that is deliberately conservative on cellular and on low-RAM devices.
final profile = await foundry.deviceProfile;
final budget = profile.availableMemoryBytes < 3 * 1024 * 1024 * 1024
    ? 400 * 1024 * 1024   // low-RAM tier: small CPU variant only
    : 2 * 1024 * 1024 * 1024;

final candidates = pkg.variants
    .where((v) => v.isCompatible && v.downloadSizeBytes <= budget)
    .toList()
  ..sort((a, b) => b.compatibilityScore.compareTo(a.compatibilityScore));

final chosen = candidates.isNotEmpty
    ? candidates.first
    : pkg.variants.firstWhere((v) => v.device == FlmDevice.cpu);

pkg.selectVariant(chosen);
```

Because variant metadata carries `platform`, `execution_provider` and `device`, the same
Dart or TypeScript code makes a correct — and *different* — decision on iOS and Android
without any platform branching in app code.

### Estimate, then download

Always show the user what a download will cost. Shared assets are counted once, which a
naive per-variant sum gets wrong:

```swift
let estimate = try await pkg.estimateDownload(variants: [chosen])
guard estimate.fitsOnDevice else { throw AppError.insufficientStorage }

// "Download 590 MB? (390 MB already on this device)"
showConfirmation(
    download: estimate.downloadBytes,
    alreadyCached: estimate.alreadyCachedBytes
)

for try await progress in pkg.download() {
    updateUI(progress.percent, stage: progress.stage)
}
```

## Downloading more than one variant

Apps that want a fast path and a fallback — for instance an NPU variant for speed and a
CPU variant that keeps working while the device is hot — can hold independent handles:

```kotlin
val npu = pkg.variant("qwen2.5-0.5b.qnn-npu")
val cpu = pkg.variant("qwen2.5-0.5b.cpu")

cpu.download()   // small, fetch first so the app is usable immediately
cpu.load()

// Upgrade in the background when on Wi-Fi.
if (foundry.deviceProfile.network == Network.UNMETERED) {
    npu.download()
}
```

The shared assets both variants reference are stored once and downloaded once.

## Version updates

Package content is checksum-addressed, so upgrading to a new version of the same package
skips anything already present locally. Shared-asset directories from the installed
version are reused rather than re-downloaded, and only genuinely new content is fetched.
For a typical point release that means downloading the changed variant, not the weights.

## Cleanup

The package spec deliberately does not record which variants consume which shared assets,
so the SDK maintains that mapping itself in Foundry-Local-owned metadata alongside the
cache. Deleting a variant removes its own directory and then any shared asset no longer
referenced by a remaining variant — no orphaned gigabytes.

## Constraints in this release

- Single-component packages only. Multi-component packages (pipelines such as diffusion,
  tool-discovery components) parse correctly but only the primary component is loadable.
- Selective download operates at variant granularity, not at the level of individual
  files within a variant.
- On-device merging of separately downloaded per-EP packages is not supported; each
  package is managed independently.
- On-device recompilation of a model is not supported.

[mp-spec]: https://github.com/microsoft/onnxruntime/blob/main/model_package/README.md
