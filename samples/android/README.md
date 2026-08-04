# Android sample

Minimal Compose app that exercises the full Foundry Local Mobile Android
binding end to end: initialise the SDK, add a remote model source, show
which variant the SDK picked and why, download with visible progress and a
working cancel, load the model, and stream a chat completion into the UI.

This is the first real consumer of the binding's public API. If something
here feels awkward, that is a finding worth reporting — the sample is meant
to expose API friction, not paper over it.

## Prerequisites

- JDK 17 (`msopenjdk-17` or Temurin 17)
- Android SDK with `platforms;android-35`, `build-tools;35.0.0`, `ndk;27.0.12077973`,
  and `cmake;3.22.1`
- The upstream Foundry Local headers, staged by
  `scripts/fetch_foundry_local.sh` from the repository root (needed by the
  binding's CMake build). Run it once after cloning:

  ```sh
  scripts/fetch_foundry_local.sh
  ```

## Layout

- `settings.gradle.kts` — composite build that includes the sibling
  `bindings/android/` project and substitutes it for the Maven coordinate
  `com.microsoft.ai.foundry.local:foundry-local-mobile`.
- `app/` — the Compose application. One activity, one `AndroidViewModel`
  that drives a state machine (`NeedsConfig` → `Configured` → `Downloading`
  → `VariantsResolved` → `Loading` → `Ready` → `Generating`).

A real consumer would drop the `includeBuild(...)` block and depend on the
published artifact from Maven Central instead. The coordinate is the same.

## Configure a model source

Do **not** commit credentials. Two paths:

**Preferred — `local.properties`.** This file is git-ignored at the repo
root, so an accidental `git add` cannot ride the credentials into a commit.
Add:

```
flm.sample.modelName=phi-4-mini
flm.sample.modelUrl=https://your-bucket.example.com/models/phi-4-mini/manifest.json
flm.sample.authHeader=Bearer <token>
```

Rebuild the app to pick the values up (they are baked in as `BuildConfig`
fields, so no rebuild = old values).

**Alternative — the on-screen form.** Leave `local.properties` alone and
enter the URL and header directly in the first screen. Nothing is
persisted; you re-enter on the next launch.

The manifest URL should point at a Foundry Local model package manifest —
the same JSON format the SDK's variant scorer expects. See
`docs/model-sources.md` for the schema.

## Build

From the repo root, with the toolchain on `PATH`:

```sh
export JAVA_HOME=/usr/lib/jvm/msopenjdk-17
export ANDROID_HOME=$HOME/android-sdk
export ANDROID_SDK_ROOT=$HOME/android-sdk
export PATH=$JAVA_HOME/bin:$PATH
cd samples/android
./gradlew :app:assembleDebug
```

The APK lands at `app/build/outputs/apk/debug/app-debug.apk`. It ships one
JNI wrapper (`libfoundry_local_mobile_jni.so`), the core
(`libfoundry_local_mobile.so`) and the NDK's `libc++_shared.so` per ABI,
for `arm64-v8a`, `armeabi-v7a` and `x86_64`.

## Run on an emulator

```sh
$ANDROID_HOME/platform-tools/adb install -r app/build/outputs/apk/debug/app-debug.apk
$ANDROID_HOME/platform-tools/adb shell am start -n \
  com.microsoft.ai.foundry.local.samples/.MainActivity
```

For an on-device run, plug in a device with USB debugging enabled and use
the same `adb install`.

## What each screen shows

1. **Config** — model name, manifest URL, optional Authorization header.
   Populated from `BuildConfig` (see above) when set.
2. **Configured** — the SDK is initialised. This screen prints the device
   profile — ABI, CPU cores, execution providers the runtime sees — so a
   tester can confirm the environment before any bytes transfer.
3. **Downloading** — a `LinearProgressIndicator` driven by the real
   `Progress` callback; percent, bytes, rate, ETA, stage and detail. The
   Cancel button calls `job.cancel()` on the coroutine running
   `addModelSource`; `JobBridge` wires that straight through to
   `flm_job_cancel` so the SDK aborts cleanly.
4. **Variants resolved** — the model files are on disk. The selected
   variant is highlighted; every other candidate is listed with its
   execution provider, device, download size, compatibility score and (if
   incompatible) the reason string the SDK returned. This is the answer to
   "why did the SDK pick this variant".
5. **Loading** — `model.load()`. Runs on `Dispatchers.IO` under the
   ViewModel's scope.
6. **Ready / Generating** — a chat history, a prompt field and a Send
   button. `completeStreaming(...)` is collected token by token into the
   pending assistant turn, which becomes a full history entry on flush.

Errors from anywhere in the pipeline route to an error card that carries
the `FoundryLocalException.status`, the human message and the raw
`detailJson` payload — the same information a production error handler
would want.

## What this sample proves, and what it does not

- **Proven**: the binding's public API compiles, the composite build wires
  the AAR into a consumer app, the ViewModel drives the whole state
  machine through the SDK, the APK carries the right ABIs.
- **Not proven end-to-end here**: an actual download and inference. You
  need a real manifest URL, a real credential (or none, if your endpoint
  is open) and a device with matching hardware. The compile signal alone
  does not tell you the streaming path works with your specific model —
  hit Send with a live endpoint and inspect the streamed output. Report
  any API friction directly against the binding.
