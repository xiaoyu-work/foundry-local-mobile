# Platform support

This document is derived from the code that runs, not from what a marketing table wishes
were true. Every entry in the tables below has a citation to a source file that
implements it.

## Summary matrix

| Target | Min OS | ABIs | On-device EPs (platform-registered) | Accelerator |
|---|---|---|---|---|
| **Android** | 8.0 (API 26) | `arm64-v8a`, `armeabi-v7a`, `x86_64` | QNN *(if Hexagon DSP present)*, XNNPACK, CPU | Qualcomm Hexagon NPU |
| **iOS / iPadOS** | 15.0 | `arm64` device; `arm64` + `x86_64` simulator | CoreML, XNNPACK, CPU | Apple Neural Engine (A12+) |
| **macOS** *(developer target only)* | 12.0 | `arm64`, `x86_64` | CoreML *(Apple silicon)*, XNNPACK, CPU | ANE on Apple silicon |
| **Linux / Windows** *(dev builds only)* | — | native | CPU | — |

Every binding — Kotlin, Swift, Dart, TypeScript — sits on the same core, so the
platform matrix above is the same across all four languages. Individual bindings do
not narrow it.

## Minimum operating system versions

**Android 8.0 (API 26.)** The core's Android build uses `ANDROID_PLATFORM=android-26`
(`scripts/build_android.sh`), which matches the AAR's `minSdk`. This is deliberately
close to the floor of what the JIT-compiled ONNX Runtime GenAI kernels support, and
covers >99% of active Android devices.

Newer Android versions have two release-relevant quirks the core already handles:

* **Android 15+ 16 KB page alignment on 64-bit devices.** Without it the library
  fails to load. `core/CMakeLists.txt` links with `-Wl,-z,max-page-size=16384` on
  Android to satisfy the loader.
* **Android 12+ `MediaProjection` background policies** are not relevant to inference
  and are not exercised by the SDK.

**iOS / iPadOS 15.0.** `scripts/build_apple.sh` uses `--ios-min 15.0` by default. This
is the oldest iOS the current toolchain officially supports and the oldest that has
the Metal shading language features CoreML relies on for ANE dispatch.

**macOS 12.0.** Applies only to developer builds (native samples, XCFramework
consumers that also want a macOS slice); not a shipping mobile target.

The versions above are the same as those defaulted by the build scripts, so a plain
`./scripts/build_android.sh` / `./scripts/build_apple.sh` produces binaries valid for
these ranges. Overriding them (`--platform 28`, `--ios-min 17`) narrows the support
range and does not automatically rebuild for older devices.

## Supported ABIs / architectures

Detected at compile time in `core/src/platform/device_profile_android.cc` and
`device_profile_apple.cc`, and reported through the device profile as `abi`.

### Android

| ABI | Silicon | ANDROID_ABI |
|---|---|---|
| `arm64-v8a` | Every 64-bit ARM Android phone/tablet shipped since 2016 | `arm64-v8a` |
| `armeabi-v7a` | 32-bit ARM devices; still relevant for entry-level phones | `armeabi-v7a` |
| `x86_64` | Emulator + Chromebooks that expose an Android runtime | `x86_64` |

`x86` (32-bit) is not produced. There is no viable inference target left on 32-bit
x86 Android.

### Apple

| Slice | Architectures | Where it runs |
|---|---|---|
| `ios-arm64` | `arm64` | Physical iPhone / iPad |
| `ios-arm64_x86_64-simulator` | `arm64` + `x86_64` (lipo'd) | Xcode Simulator on Apple silicon and Intel Macs |
| `macos-arm64_x86_64` *(optional, `--macos`)* | `arm64` + `x86_64` (lipo'd) | Apple silicon and Intel Macs |

Simulator slices are combined into one fat framework because
`xcodebuild -create-xcframework` refuses to accept two frameworks that share the same
platform + variant tag.

## Execution providers

The device profile enumerates every execution provider the platform code can offer,
scores them by a numeric priority (lower wins), and the runtime overlays whichever ones
it actually managed to register. Only the intersection is available to model-package
variant selection.

The lists below are what `FillExecutionProviders` registers on each platform.

### Android — `device_profile_android.cc`

| EP name | Device | Priority | When it appears |
|---|---|---|---|
| **QNN** | NPU | 0 | Registered only when `/vendor/lib64/libQnnHtp.so` or `libcdsprpc.so` is present. Adds a `dsp_arch=<v…>` compatibility string derived from `ro.hardware` / `ro.board.platform`. |
| **XNNPACK** | CPU | 20 | Always. The fast CPU path on ARM. |
| **CPU** | CPU | 30 | Always. Universal fallback. |

Qualcomm SoCs the platform code currently maps to a Hexagon DSP architecture (this is
what makes an NPU variant either match or reject a device):

| Board prefix | DSP arch | SoC |
|---|---|---|
| `sun` | `v79` | Snapdragon 8 Elite |
| `pineapple` | `v75` | Snapdragon 8 Gen 3 |
| `kalama` | `v73` | Snapdragon 8 Gen 2 |
| `taro` | `v69` | Snapdragon 8 Gen 1 |
| `lahaina` | `v68` | Snapdragon 888 |

Variants declaring a higher `dsp_arch` than the device has are rejected as
incompatible; variants declaring a lower one run with a size-of-gap penalty in the
score. See `ModelPackage::ScoreCompatibilityString` in `core/src/model_package.cc`.

**NNAPI, GPU EPs, VitisAI, OpenVINO.** These are recognised by the shared classifier
in `core/src/device_profile.cc` (`ClassifyExecutionProvider`) — if the runtime
registers one, the profile categorises it correctly (NPU or GPU) with a sensible
priority. **The Android platform code does not currently register them itself**; it
lists only QNN, XNNPACK and CPU. This is a soft limitation, not an ABI break: any EP
the runtime adds later shows up automatically through
`MergeRuntimeExecutionProviders`.

### Apple — `device_profile_apple.cc`

| EP name | Device | Priority | When it appears |
|---|---|---|---|
| **CoreML** | NPU | 0 | Registered whenever `has_npu` is true — on a real iOS/iPadOS device (A12 and newer, i.e. everything modern iOS supports), and on Apple silicon Macs. Not registered in the iOS Simulator or on Intel Macs. |
| **XNNPACK** | CPU | 20 | Always. |
| **CPU** | CPU | 30 | Always. |

CoreML decides ANE-vs-GPU-vs-CPU placement itself at compile time from the model. The
mobile SDK does not force a placement; it publishes `compute_units=all` as the CoreML
preference, and lets CoreML pick.

The iOS **simulator** intentionally has no ANE and CoreML runs on the host CPU there,
so a variant that requires CoreML/NPU will match on device but fall back to CPU in the
simulator.

### Desktop — `device_profile_desktop.cc`

Only the **CPU** EP is registered. Linux and Windows are developer targets, not
shipping targets, and this keeps the core buildable on a CI runner without an
emulator or a device.

## Model size and download budgets

The SDK enforces per-device budgets rather than trusting an app to know how big a
device can go. These apply to model acquisition through
`flm_manager_add_model_source_async` — the two shipping mobile model sources are a
model bundled into the app (no download) and a URL the app itself hosts (subject to
these budgets). There is no built-in Foundry Local catalog fetch on mobile; the
desktop catalog publishes CUDA/DirectML/OpenVINO/x64 builds that are not the shape
mobile targets need.

The budget constants live in `core/src/device_profile.cc`:

| Rule | Value | Where |
|---|---|---|
| Max model bytes | 45% of available RAM (halved when the device is hot or in low-power mode) | `DeviceProfile::MaxModelBytes` |
| Max silent download | 50% of free storage | `DeviceProfile::CanDownloadSilently` |
| Max silent download on a metered link | 20 MB | `DeviceProfile::CanDownloadSilently` |
| Variant rejected as "too large" | download size × 3 > max model bytes | `ModelPackage::ScoreVariants` |
| Unknown/failed memory detection | 1 GB budget | `DeviceProfile::MaxModelBytes` |

If detection fails outright the SDK errs on the small side. It is preferable to
download the CPU int4 variant on a device that could run the NPU one than to load a
model the OS will kill on activation.

## Known limitations

* **Foundry Local runtime is loaded via `dlopen` at run time.** The mobile SDK
  compiles against the upstream C headers (staged by
  `scripts/fetch_foundry_local.sh`) but does *not* link the runtime library. That
  library must be present in the app's linker search path at run time; without it
  `flm_is_runtime_available()` returns false and every operation that needs the
  runtime fails with `FLM_ERROR_RUNTIME_UNAVAILABLE`. This is what makes the mobile
  SDK cross-compilable on a public CI runner without the proprietary runtime binary.
* **No NNAPI or Android GPU EP is registered by device detection.** They are
  supported by the classifier if the runtime provides them, but detection does not
  add them proactively. On a device without a Hexagon DSP the shipping EPs are
  XNNPACK and plain CPU.
* **iOS simulator has no ANE.** CoreML variants match by name but execute on the
  simulator's CPU. Test NPU code paths on device.
* **`armeabi-v7a` targets are 32-bit and inherit its address-space cap.** Practical
  ceiling ~2 GB per process on most vendors, less on some. Do not ship gigabyte-plus
  models to this ABI.
* **Windows and Linux are not shipping targets.** They compile so the core can be
  built and inspected on a developer's laptop and by CI. There is no packaging story
  for either, and thermal, low-power and network state are not detected there.
* **Thermal state, low-power mode and network metering** are pushed down from the
  binding on both platforms (`flm_manager_notify_lifecycle`). If a binding does not
  push them, the core assumes nominal thermal, no low-power mode, and an unknown
  network, which biases toward smaller variants and prompts before large downloads.

## References

* `core/src/device_profile.cc` — the classifier and memory/storage budgets.
* `core/src/platform/device_profile_android.cc` — Android detection and EP registration.
* `core/src/platform/device_profile_apple.cc` — Apple detection and EP registration.
* `core/src/model_package.cc` — variant scoring and compatibility-string matching.
* `docs/architecture.md` — the five-layer design this document is a projection of.
