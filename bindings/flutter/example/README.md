# foundry_local_mobile — example app

Path-only demo of the plugin exercised on Android:

1. Initialise `FoundryLocal`.
2. Load a **local model directory** with `FoundryLocal.loadModel(path)`.
3. Watch native load progress.
4. Create a chat session and stream a completion token by token.

## Running

```bash
flutter run \
  --dart-define=FLM_MODEL_PATH=/absolute/path/to/model
```

`FLM_MODEL_PATH` is optional; if omitted you can type the path on-screen.

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
