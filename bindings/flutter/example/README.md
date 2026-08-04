# foundry_local_mobile — example app

End-to-end demo of the plugin exercised on Android:

1. Initialise `FoundryLocal`.
2. Register a **user-supplied remote model source** (URL + optional auth
   header). Nothing is hardcoded — you provide both on-screen or via
   `--dart-define`. Credentials never leave widget state.
3. Show the resolved model package's variant table and the variant the
   core picked for this device, so you can see *why* one was chosen.
4. Watch the download over the plugin's real progress callback, and abort
   it at any time with the cancel button (backed by `CancelToken`).
5. Load the model and stream a chat completion token by token.

## Running

```bash
flutter run \
  --dart-define=FLM_MODEL_URL=https://models.example.com/phi-4-mini/manifest.json \
  --dart-define=FLM_MODEL_AUTH="Bearer ..."                                       \
  --dart-define=FLM_MODEL_NAME=phi-4-mini
```

All three `--dart-define`s are optional; anything you omit shows up as an
empty on-screen field you can fill in at run time.

## Building an APK

```bash
export JAVA_HOME=/usr/lib/jvm/msopenjdk-17
export ANDROID_SDK_ROOT=$HOME/android-sdk
export ANDROID_NDK_HOME=$HOME/android-ndk-r27c
cd bindings/flutter/example
flutter build apk --debug
```

The resulting APK ships `libfoundry_local_mobile.so` and `libc++_shared.so`
for `arm64-v8a`, `armeabi-v7a`, and `x86_64`.

## Two setup details worth knowing before copying this into a real app

Both of these are handled inside this example's own configuration, but the
next person adopting the plugin will hit them and there is no framework
message that points at either one:

- **INTERNET permission.** `flutter create` does not include
  `<uses-permission android:name="android.permission.INTERNET"/>` in the
  app manifest. Remote model sources go through the plugin's transport,
  which fails immediately without it. See
  `android/app/src/main/AndroidManifest.xml`.
- **`ndkVersion` pin.** The plugin's `ExternalNativeBuild` requires NDK
  `26.1.10909125`. Deferring to `flutter.ndkVersion` picks something
  older and Gradle warns on every build (and configure sometimes fails
  outright). The example pins it in `android/app/build.gradle`. It also
  pins `abiFilters` to the three ABIs the plugin ships — otherwise a
  stray `lib/x86/libflutter.so` slice would install on 32-bit x86
  devices with no matching `libfoundry_local_mobile.so`.

## Consuming the plugin

`pubspec.yaml` pulls the plugin in as `foundry_local_mobile: { path: ../ }`,
i.e. exactly as a real app would from pub.dev once the plugin ships. No
files under `lib/` reach into the plugin's `src/`; everything runs through
the public `foundry_local_mobile.dart` barrel export.
