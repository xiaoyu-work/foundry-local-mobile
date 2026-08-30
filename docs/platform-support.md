# Platform support

This document is derived from the code that runs, not from what a marketing table wishes
were true. Every entry in the tables below has a citation to a source file that
implements it.

## Summary matrix

| Target | Min OS | ABIs | On-device EPs (platform-registered) | Accelerator |
|---|---|---|---|---|
| **Android** | 8.0 (API 26) | `arm64-v8a`, `x86_64` | QNN *(if Hexagon DSP present)*, XNNPACK, CPU | Qualcomm Hexagon NPU |
| **iOS / iPadOS** | 15.0 | `arm64` device; `arm64` + `x86_64` simulator | CoreML, XNNPACK, CPU | Apple Neural Engine (A12+) |
| **macOS** *(developer target only)* | 12.0 | `arm64` | CoreML, XNNPACK, CPU | Apple Neural Engine |
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
| `x86_64` | Emulator + Chromebooks that expose an Android runtime | `x86_64` |

The pinned OGA runtime supports only 64-bit Android targets. `armeabi-v7a` and
`x86` are therefore not produced.

If your own app builds an `x86` slice — Flutter's default template does, and some
dependencies pull one in — the resulting APK will install on a 32-bit x86 image and
then fail at the first `dlopen` of the core, because the ABI it advertises is one the
SDK does not ship. That surfaces as a crash on launch rather than as an install-time
refusal, which is the worse of the two. Pin your ABI set to what the SDK ships:

```kotlin
android {
    defaultConfig {
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }
}
```

Both sample apps in this repo do exactly that. Inspect the packaged APK before release
to confirm that no `lib/x86/` slice survives.

### Apple

| Slice | Architectures | Where it runs |
|---|---|---|
| `ios-arm64` | `arm64` | Physical iPhone / iPad |
| `ios-arm64_x86_64-simulator` | `arm64` + `x86_64` (lipo'd) | Xcode Simulator on Apple silicon and Intel Macs |
| `macos-arm64` *(optional, `--macos`)* | `arm64` | Apple silicon Macs |

Simulator slices are combined into one fat framework because
`xcodebuild -create-xcframework` refuses to accept two frameworks that share the same
platform + variant tag.

## Execution providers

The device profile enumerates every execution provider the platform code believes is
available, scored by a numeric priority (lower wins). This is informational: it is
reported through `flm_manager_get_device_profile_json` so an app can decide which
`execution_provider` to pass to `loadModel()`. The SDK does not use this list to
automatically pick a provider or score model-package variants itself — that decision is
either made explicitly by the caller, or (for OGA package directories) resolved by OGA
against whichever provider you pass in.

The lists below are what `FillExecutionProviders` registers on each platform.


### Android — `device_profile_android.cc`

| EP name | Device | Priority | When it appears |
|---|---|---|---|
| **QNN** | NPU | 0 | Registered only when `/vendor/lib64/libQnnHtp.so` or `libcdsprpc.so` is present. Adds a `dsp_arch=<v…>` compatibility string derived from `ro.hardware` / `ro.board.platform`. |
| **XNNPACK** | CPU | 20 | Always. The fast CPU path on ARM. |
| **CPU** | CPU | 30 | Always. Universal fallback. |

Qualcomm SoCs the platform code currently maps to a Hexagon DSP architecture (reported
as `dsp_arch` in the device profile, for the app's own use when choosing a QNN
`execution_provider`/`provider_options`):

| Board prefix | DSP arch | SoC |
|---|---|---|
| `sun` | `v79` | Snapdragon 8 Elite |
| `pineapple` | `v75` | Snapdragon 8 Gen 3 |
| `kalama` | `v73` | Snapdragon 8 Gen 2 |
| `taro` | `v69` | Snapdragon 8 Gen 1 |
| `lahaina` | `v68` | Snapdragon 888 |

The `compatibility_string` (e.g. `dsp_arch=v75`) is reported alongside the rest of the
device profile for the app's own use — for example, to decide which OGA package variant
to request via `execution_provider`/`provider_options`. The SDK itself does not compare
this string against anything or reject a model as incompatible; there is no variant
scoring in the current core (that concept was removed along with the model-package
catalog layer).

**NNAPI, GPU EPs, VitisAI, OpenVINO.** These are recognised by the shared classifier
in `core/src/device_profile.cc` (`ClassifyExecutionProvider`) so that, if a future
runtime-reported EP list is merged in, the profile categorises it correctly (NPU or GPU)
with a sensible priority. **The Android platform code does not currently register them
itself**; it lists only QNN, XNNPACK and CPU, and nothing in the current core calls
`MergeRuntimeExecutionProviders` to add runtime-discovered providers on top of that list.

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
shipping targets, and this keeps the core buildable on a developer machine without
an emulator or a device.

## Model size budgets

The SDK enforces a per-device memory budget before loading a model. This applies when
`flm_manager_load_model_async` is called — the model path is validated and memory
availability is checked before OGA loads the model. There is no download budget or
variant-size scoring in this SDK: it never downloads anything, and package-variant
resolution is delegated to OGA once you specify an `execution_provider`.

The budget constant lives in `core/src/device_profile.cc`:

| Rule | Value | Where |
|---|---|---|
| Max model bytes | 45% of available RAM (halved when the device is hot or in low-power mode) | `DeviceProfile::MaxModelBytes` |
| Unknown/failed memory detection | 1 GB budget | `DeviceProfile::MaxModelBytes` |

If detection fails outright the SDK errs on the small side and a model whose on-disk
size exceeds the budget fails fast with `FLM_ERROR_MEMORY_PRESSURE` rather than loading
and risking an OS kill.

## Known limitations

* **ONNX Runtime GenAI is linked directly into the core, not loaded dynamically.** The
  core's `CMakeLists.txt` builds OGA from source (staged by
  `scripts/fetch_onnxruntime_genai.sh`, pinned to commit
  [`9d336e4`](https://github.com/microsoft/onnxruntime-genai/commit/9d336e4db4e49eeceda909517b882c0d73cc6c86))
  or against an installed package, and links it in at build time. `flm_is_runtime_available()`
  is unconditionally true once the library is linked; there is no separate runtime
  binary the app has to supply, and no `FLM_ERROR_RUNTIME_UNAVAILABLE` path in current
  builds. The Android/Flutter build does still ship `libonnxruntime-genai.so` and
  `libonnxruntime.so` as separate shared libraries alongside `libfoundry_local_mobile.so`
  (see [building.md](building.md#build-the-android-aar)), so all of them must be present
  in the APK for the app to start.
* **No NNAPI or Android GPU EP is registered by device detection.** They are
  supported by the classifier if the runtime provides them, but detection does not
  add them proactively. On a device without a Hexagon DSP the shipping EPs are
  XNNPACK and plain CPU.
* **iOS simulator has no ANE.** CoreML-targeted models match by name but execute on the
  simulator's CPU. Test NPU code paths on device.
* **Windows and Linux are not shipping targets.** They compile so the core can be
  built and inspected on a developer's laptop. There is no packaging story
  for either, and thermal and low-power state are not detected there.
* **Thermal state and low-power mode** are pushed down from the binding on both
  platforms (`flm_manager_notify_lifecycle`). If a binding does not push them, the
  core assumes nominal thermal and no low-power mode. Connectivity is deliberately
  not monitored because the SDK never performs network I/O.

## References

* `core/src/device_profile.cc` — the classifier and the memory budget.
* `core/src/platform/device_profile_android.cc` — Android detection and EP registration.
* `core/src/platform/device_profile_apple.cc` — Apple detection and EP registration.
* `docs/architecture.md` — the five-layer design this document is a projection of.
