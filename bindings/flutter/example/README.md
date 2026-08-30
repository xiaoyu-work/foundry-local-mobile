# foundry_local_mobile - example app

Chat-first demo of the plugin on Android and iOS:

1. Initialise `FoundryLocal`.
2. Load a local ONNX Runtime GenAI model directory.
3. Show the loaded model and execution provider.
4. Stream multi-turn responses into a familiar conversation UI.

## Stage the bundled iOS model

iOS apps cannot load a model from an arbitrary host path. Stage the six runtime
files before building; the script creates ignored symlinks, so the roughly 1 GB
model is neither copied nor committed:

```bash
./scripts/fetch_onnxruntime_genai.sh
./bindings/ios/scripts/build_xcframework.sh --build-type Release

cd bindings/flutter/example
./scripts/stage_model.sh /absolute/path/to/qwen3-0.6b-int4-onnx
flutter run -d <ios-device-id>
```

The first two commands build and stage both native XCFrameworks consumed by
the local Flutter plugin. Keep those generated frameworks in the plugin's
ignored `ios/Frameworks` directory while building the example locally.

The source directory must contain `chat_template.jinja`, `genai_config.json`,
`model.onnx`, `model.onnx.data`, `tokenizer.json`, and
`tokenizer_config.json`. The app resolves the copied Flutter asset directory at
runtime and automatically loads it with the CPU execution provider.

## Run on Android

Pass the model directory on the Android device at build time:

```bash
flutter run \
  --dart-define=FLM_MODEL_PATH=/absolute/path/to/model
```

## Building an APK

```bash
export JAVA_HOME=/usr/lib/jvm/msopenjdk-17
export ANDROID_SDK_ROOT=$HOME/android-sdk
export ANDROID_NDK_HOME=$HOME/android-ndk-r27c
cd bindings/flutter/example
flutter build apk --debug
```

The resulting APK ships `libfoundry_local_mobile.so` and `libc++_shared.so`
for `arm64-v8a` and `x86_64`.

## Consuming the plugin

`pubspec.yaml` pulls the plugin in as `foundry_local_mobile: { path: ../ }`.
The example uses only the public `foundry_local_mobile.dart` barrel export.
