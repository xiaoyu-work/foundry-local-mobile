# Android sample

Minimal Compose app that exercises the Foundry Local Mobile Android binding:
initialise the SDK, load a model from a local directory path, and stream a
chat completion into the UI.

## Prerequisites

- JDK 17 (`msopenjdk-17` or Temurin 17)
- Android SDK with `platforms;android-35`, `build-tools;35.0.0`, `ndk;27.0.12077973`,
  and `cmake;3.31.6`
- The upstream ONNX Runtime GenAI sources, staged by
  `scripts/fetch_onnxruntime_genai.sh` from the repository root.

## Usage

The sample loads a model from a local directory path on the device. Push a
model directory to the device filesystem, then enter its path in the UI.

```sh
adb push /path/to/local/model /data/local/tmp/model
```

## Build

```sh
cd samples/android
./gradlew :app:assembleDebug
```

## What each screen shows

1. **Config** — enter the path to a local OGA model directory.
2. **Configured** — the SDK is initialised with the device profile shown.
3. **Loading** — `loadModel(path)` runs.
4. **Ready / Generating** — chat with the loaded model.
