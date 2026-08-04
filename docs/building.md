# Building Foundry Local Mobile from source

Everything ships as source under one repository. There are three kinds of build:

* **Core** — the C++ mobile core plus the flat C ABI. Every binding sits on this.
* **Cross** — the core cross-compiled for Android ABIs or as an Apple XCFramework.
* **Binding** — the language-specific package (AAR, Swift Package, pub package, npm
  package), each of which consumes the corresponding cross-build.

If you only want to try the SDK from an app, use the published binary packages instead
(see the [README](../README.md)). This document is for people building the SDK itself.

## Prerequisites

| Tool | Minimum | Notes |
|---|---|---|
| CMake | 3.22 | The core sets `cmake_minimum_required(3.22)`. |
| A C++20 compiler | GCC 13 / Clang 15 / MSVC 19.36 | The core is C++20 and uses `<filesystem>`. |
| Git | any recent version | The fetch step clones the upstream SDK. |
| Android NDK | r26+ (verified r27c) | Required only for the Android cross-build. `ANDROID_NDK_HOME` must point at it. |
| Xcode | 15.0+ | Required only for the Apple cross-build. Full Xcode, not just the command-line tools. |
| Ninja *(optional)* | any | Detected automatically; the build falls back to Unix Makefiles / Xcode. |
| Dart / Flutter *(optional)* | Flutter 3.19+ (Dart 3.3+) | Only needed to build the Flutter binding. |
| Node *(optional)* | 20 LTS | Only needed to build the React Native binding. |
| Java + Android SDK *(optional)* | JDK 17 + platforms;android-35, build-tools;35.0.0, ndk;27.0.12077973, cmake;3.22.1 | Only needed to build the Android AAR (Gradle). See [Build the Android AAR](#build-the-android-aar). |

The upstream Foundry Local SDK headers are **not** vendored in this repository; they are
staged by `scripts/fetch_foundry_local.sh` (see below).

## One-time setup

```bash
# 1. Stage the upstream Foundry Local SDK headers into third_party/.
./scripts/fetch_foundry_local.sh

# 2. (Optional) Point the fetch script at a checkout you already have on disk.
./scripts/fetch_foundry_local.sh --local /path/to/your/Foundry-Local

# 3. (Optional) Pin a specific upstream ref (tag, branch or commit).
./scripts/fetch_foundry_local.sh --ref cli-preview-0.10.2
```

The staging destination (`third_party/foundry-local/include/`) is one of two paths the
core's `CMakeLists.txt` probes, so no `-D` flag is needed after this. To point CMake at a
custom location instead, pass `-DFLM_FOUNDRY_LOCAL_INCLUDE_DIR=/absolute/path` to
`cmake` and skip the fetch step.

`fetch_foundry_local.sh` is idempotent. Running it twice does nothing on the second
call unless `--force` or `--ref <new-ref>` is passed. `--verify` checks the recorded
SHA-256 without re-fetching.

## Build the core

For a plain native build (this is what CI runs to prove the code compiles cleanly):

```bash
cmake -S core -B build/linux -DCMAKE_BUILD_TYPE=Release
cmake --build build/linux --parallel
```

Or, equivalently, via the convenience driver:

```bash
./scripts/build.sh linux
```

Options exposed on the CMake command line:

| Option | Default | Meaning |
|---|---|---|
| `-DFLM_BUILD_SHARED=ON\|OFF` | `ON` | Build a shared library. `OFF` produces a static archive with `FLM_STATIC` defined. |
| `-DFLM_BUILD_EXAMPLES=ON\|OFF` | `OFF` | Build the native example programs under `core/examples/`. |
| `-DFLM_FOUNDRY_LOCAL_INCLUDE_DIR=<path>` | *(auto)* | Absolute path to `Foundry-Local/sdk_v2/cpp/include`. Overrides the fetch-staged location. |
| `-DCMAKE_BUILD_TYPE=<type>` | *(unset)* | Standard CMake build type. Use `Release` or `RelWithDebInfo` for anything you ship. |

Output: `build/linux/libfoundry_local_mobile.so` (or `.dylib`, `.dll`).

## Cross-compile for Android

```bash
export ANDROID_NDK_HOME=/path/to/android-ndk-r26d
./scripts/build_android.sh                       # all three ABIs
./scripts/build_android.sh --abi arm64-v8a       # just one
./scripts/build_android.sh --build-type Debug    # skip optimisation
```

Layout:

```
build/android/
└── jniLibs/
    ├── arm64-v8a/
    │   ├── libc++_shared.so
    │   └── libfoundry_local_mobile.so
    ├── armeabi-v7a/
    │   ├── libc++_shared.so
    │   └── libfoundry_local_mobile.so
    └── x86_64/
        ├── libc++_shared.so
        └── libfoundry_local_mobile.so
```

which is exactly what an Android Gradle module consumes from `jniLibs.srcDirs`.
`libc++_shared.so` is copied from the NDK because `libfoundry_local_mobile.so` links
against it dynamically (see `readelf -d`); an AAR that ships the core `.so` without
its STL crashes at first load with `dlopen failed: cannot locate libc++_shared.so`.
If your Gradle module already provides `libc++_shared.so` from another native
dependency, the duplicate is harmless — Gradle keeps one — but versions must match,
so prefer the copy staged here.

Release binaries are stripped with the NDK's `llvm-strip` after copying, so the
shipped `.so`s carry no debug symbols; pass `--no-strip` to keep them for local
`addr2line`.

The 64-bit ABIs are linked with `-Wl,-z,max-page-size=16384`, which produces LOAD
segments aligned to 16 KB. Android 15+ on 64-bit devices refuses to map a library
whose LOAD segments are only 4 KB aligned, so this is a shipping requirement, not a
recommendation. `scripts/build_android.sh` asserts the alignment on the artifact
itself after each build and refuses to complete if it regresses. To check by hand
after any manual rebuild:

```bash
llvm-readelf -lW build/android/jniLibs/arm64-v8a/libfoundry_local_mobile.so \
  | awk '$1 == "LOAD" { print $NF }'   # expect 0x4000 on every row
```

`ANDROID_PLATFORM` defaults to `android-26`, matching the SDK's `minSdk 26`. Override
with `--platform 28` if you need a newer sysroot for a specific test.

## Cross-compile for Apple

Requires a macOS host with a full Xcode install (not just the command-line tools —
`xcodebuild` needs the iPhoneOS and iPhoneSimulator SDKs).

```bash
./scripts/build_apple.sh                    # iOS device + iOS simulator (arm64 + x86_64)
./scripts/build_apple.sh --macos            # also build a macOS slice
./scripts/build_apple.sh --ios-min 16.0     # deployment target override
```

Output:

```
build/apple/FoundryLocalMobile.xcframework/
├── ios-arm64/FoundryLocalMobile.framework/
├── ios-arm64_x86_64-simulator/FoundryLocalMobile.framework/
└── [macos-arm64_x86_64/FoundryLocalMobile.framework/]  (only with --macos)
```

Each framework contains the public headers under `Headers/foundry_local_mobile/` and a
`module.modulemap` so Swift can `import FoundryLocalMobile` without a shim header.

## Build the Android AAR

The Android binding under `bindings/android/` is a Gradle module that runs
`externalNativeBuild` against the core's CMake, links a JNI wrapper, and packages
everything as an AAR. **Prerequisites**: JDK 17 and an Android SDK with the exact
components `bindings/android/build.gradle.kts` pins.

Install the SDK components with `sdkmanager`:

```bash
export ANDROID_HOME=/path/to/android-sdk

$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --install \
    "platform-tools" \
    "platforms;android-35" \
    "build-tools;35.0.0" \
    "ndk;27.0.12077973" \
    "cmake;3.22.1"

yes | $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --licenses
```

Then either run through the driver:

```bash
export JAVA_HOME=/usr/lib/jvm/msopenjdk-17
./scripts/build.sh android-binding
```

or invoke the module's wrapper directly:

```bash
cd bindings/android
./gradlew assembleRelease
```

Output: `bindings/android/build/outputs/aar/foundry-local-mobile-release.aar`
(~2.3 MB). The AAR ships all three ABIs, each with `libfoundry_local_mobile.so`,
`libfoundry_local_mobile_jni.so`, and `libc++_shared.so`.

The Gradle wrapper (`bindings/android/gradlew` + `gradle/wrapper/`) pins the exact
Gradle distribution AGP 8.5.2 needs; a system-wide Gradle install is not required.

If you prefer to skip Gradle and consume `jniLibs/` directly from your own Android
project — for example when the app already has native code and its own AAR pipeline —
run `./scripts/build_android.sh` and point `sourceSets.main.jniLibs.srcDirs` at
`build/android/jniLibs/` instead.

## Everything at once

`scripts/build.sh` sequences the individual scripts:

```bash
./scripts/build.sh fetch      # stage the SDK
./scripts/build.sh linux      # native build
./scripts/build.sh android    # all three ABIs
./scripts/build.sh apple      # XCFramework (macOS only)
./scripts/build.sh all        # fetch + android + apple (apple skipped on non-macOS)
./scripts/build.sh clean      # delete build/ and third_party/foundry-local/
```

Flags after `--` are forwarded to the underlying script:

```bash
./scripts/build.sh android arm64-v8a -- --build-type Debug --platform 28
./scripts/build.sh apple -- --macos --clean
```

## Build the platform bindings

Each binding lives under `bindings/<platform>/` and consumes the cross-build output
above. They are built with their platform's native tooling; see each binding's own
README for the exact command.

| Binding | Consumes | Build |
|---|---|---|
| `bindings/android` | `core/` sources (rebuilt inside AGP) | `./gradlew assembleRelease` from `bindings/android/`, or `./scripts/build.sh android-binding`. See [Build the Android AAR](#build-the-android-aar). |
| `bindings/ios` | `build/apple/FoundryLocalMobile.xcframework` | `swift build` or Xcode |
| `bindings/flutter` | Android + iOS cross-builds | `flutter build` (in the sample) or `dart pub publish --dry-run` |
| `bindings/react-native` | Android + iOS cross-builds | `npm pack` |

## Where artifacts land

| Command | Artifact |
|---|---|
| `./scripts/build.sh linux` | `build/linux/libfoundry_local_mobile.so` |
| `./scripts/build_android.sh` | `build/android/jniLibs/<abi>/libfoundry_local_mobile.so` |
| `./scripts/build.sh android-binding` | `bindings/android/build/outputs/aar/foundry-local-mobile-release.aar` |
| `./scripts/build_apple.sh` | `build/apple/FoundryLocalMobile.xcframework/` |
| CI `Release` workflow | `foundry-local-mobile-{android-jniLibs.zip,android.aar,apple-xcframework.zip,flutter.tar.gz,react-native.tgz}` on the tagged GitHub Release. |

## Troubleshooting

**`Foundry Local headers not found. Run scripts/fetch_foundry_local.sh…`**
The CMake configure emits this when neither the fetch-staged path nor a sibling
`Foundry-Local/` checkout has `sdk_v2/cpp/include/foundry_local/foundry_local_c.h`. Run
`./scripts/fetch_foundry_local.sh`. If you already have a checkout somewhere unusual,
run `./scripts/fetch_foundry_local.sh --local /path/to/Foundry-Local` or configure with
`-DFLM_FOUNDRY_LOCAL_INCLUDE_DIR=/absolute/path`.

**`ANDROID_NDK_HOME is not set.`**
The Android cross-build requires the NDK. Install it with `sdkmanager --install
"ndk;26.3.11579264"` (or newer) and export
`ANDROID_NDK_HOME=$ANDROID_HOME/ndk/26.3.11579264`. If your tooling only sets
`ANDROID_NDK_ROOT`, the script falls back to it.

**`NDK toolchain file not found at .../build/cmake/android.toolchain.cmake`**
`ANDROID_NDK_HOME` points at the SDK root or an incomplete NDK unpack. Verify with
`ls "$ANDROID_NDK_HOME"/build/cmake/`.

**`this script must run on macOS`**
`build_apple.sh` cannot cross-compile Apple binaries from Linux or Windows; Apple's
toolchain and code signing are macOS-only. Use a macOS runner or a Mac.

**`Both … represent two equivalent library definitions`**
`xcodebuild -create-xcframework` refuses two frameworks that share the same
platform+variant tag. `build_apple.sh` avoids this by lipo-ing the arm64 and x86_64
simulator slices into a single simulator framework before invoking `xcodebuild`; if
you are calling `xcodebuild -create-xcframework` yourself, do the same lipo step.

**`ld: warning: could not find object file symbol for symbol …`**
Almost always a stale build tree after switching architectures. `./scripts/build.sh
clean` (or delete `build/`) and retry.

**16 KB page-alignment failure on Android 15.**
`libfoundry_local_mobile.so` for `arm64-v8a` and `x86_64` must have its LOAD
segments aligned to 16 KB (0x4000), otherwise Android 15+ refuses to `dlopen`
it on 64-bit devices. `scripts/build_android.sh` checks this and fails the
build if it regresses; the flag delivering it is
`-Wl,-z,max-page-size=16384`, set in `core/CMakeLists.txt` under `if(ANDROID)`.
If your own JNI library links to the core, apply the same link option or its
LOAD segments will fall back to 4 KB and the whole app fails to start on
Android 15+.

**`dlopen failed: cannot locate library "libc++_shared.so"`**
The core's `.so` is built against `c++_shared` and lists `libc++_shared.so` in
its dynamic NEEDED entries. If you inject the core into an AAR yourself
(rather than using the produced `jniLibs/`), you must ship `libc++_shared.so`
alongside it in the same ABI directory. `scripts/build_android.sh` does this
copy automatically; anywhere else, copy it from
`<ndk>/toolchains/llvm/prebuilt/<host>/sysroot/usr/lib/<triple>/libc++_shared.so`.

**Flutter/RN builds fail with `libfoundry_local_mobile.so not found`.**
The binding-level Gradle/Xcode integration expects the cross-build to have already run.
Run `./scripts/build_android.sh` (or `build_apple.sh`) first, then rebuild the binding.

**`Multiple projects in this build have project directory 'bindings/android'`.**
An out-of-date `bindings/android/settings.gradle.kts` that both hosts the root
project and `include`-s the same directory. Update to the current file, which
declares only `rootProject.name = "foundry-local-mobile"`.

**`Failed to install the following Android SDK packages as some licences have not been accepted`.**
The SDK components pinned in `bindings/android/build.gradle.kts` (see the
[prerequisites table](#prerequisites)) need licence acceptance. Run
`yes | $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --licenses` before
invoking Gradle.

**`UnsatisfiedLinkError: No implementation found for … NativeBridge.xxx`.**
The JNI wrapper `.so` is present but does not export a `Java_*` symbol the
Kotlin `external fun` calls. Reproduce the CI check locally:

```bash
python3 scripts/list_kotlin_native_symbols.py bindings/android/src/main/kotlin \
  > /tmp/kt.txt
llvm-nm -D --defined-only \
  bindings/android/build/outputs/aar/foundry-local-mobile-release.aar/jni/arm64-v8a/libfoundry_local_mobile_jni.so \
  | awk '$2 == "T" && $3 ~ /^Java_/ { print $3 }' | sort > /tmp/jni.txt
diff /tmp/kt.txt /tmp/jni.txt
```

The two lists must be identical.

## Continuous integration

The `CI` workflow (`.github/workflows/ci.yml`) runs the Linux core build with `-Werror`,
`shellcheck` on every script, YAML parse on every workflow, the Android core cross-build
on every ABI, the Apple XCFramework build, and the Android binding's `assembleRelease`
task with a JNI symbol reconciliation step that catches Kotlin ↔ JNI drift. The `Release` workflow
(`.github/workflows/release.yml`) builds every platform artifact on a `v*.*.*` tag and
attaches them to the GitHub Release.

Neither workflow runs end-to-end inference: the Foundry Local runtime library is the
part the core `dlopen`s at run time on device and is not distributed as a public
package. The build itself is the useful signal.
