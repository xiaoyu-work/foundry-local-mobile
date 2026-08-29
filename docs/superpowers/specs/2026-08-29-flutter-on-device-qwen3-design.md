# Flutter On-Device Qwen3 Validation App

**Date:** 2026-08-29

## Goal

Extend `bindings/flutter/example` into a self-contained iOS sample that loads
`JamshaidF/qwen3-0.6b-instruct-cpu-int4-onnx` through the local
`foundry_local_mobile` Flutter SDK and proves streaming chat inference on the connected
physical iPhone.

The first acceptance target is iOS hardware. The existing Android example remains
buildable, but Android device validation is outside this iteration because no Android
device is connected.

## Chosen Approach

Modify the existing Flutter plugin example rather than creating another sample app.
The example already consumes the SDK through its public Dart API, so extending it tests
the same integration path a Flutter customer uses without duplicating package and CI
configuration.

The model is bundled with the app. It is staged locally under a git-ignored asset
directory and copied into the iOS app bundle by Flutter. The app resolves the installed
asset directory natively and passes that directory directly to the path-only SDK. It
does not read the 1 GB external-data file into Dart memory and does not copy the model
into the writable sandbox at first launch.

## Repository Layout

The implementation adds or updates these areas:

```text
bindings/flutter/example/
├── assets/models/qwen3_cpu_int4/       # staged locally; ignored by git
├── ios/                                # standard Flutter iOS runner
├── lib/
│   ├── main.dart                       # app composition
│   └── src/
│       ├── bundled_model_locator.dart  # asset-path channel
│       ├── chat_controller.dart        # SDK lifecycle and state
│       └── home_screen.dart            # validation UI
├── test/                               # controller/widget tests
└── pubspec.yaml                        # model asset registration

scripts/
└── stage_flutter_example_model.sh      # validates and stages a flat OGA model
```

The large model files are never committed. The staging script accepts a source model
directory, validates the required flat-OGA files, and materializes these six runtime
files:

```text
chat_template.jinja
genai_config.json
model.onnx
model.onnx.data
tokenizer.json
tokenizer_config.json
```

The repository's `.gitattributes` is metadata for Hugging Face and is not bundled.
The runtime files are placed
under the example assets directory. On the current workstation the source is
`/Users/vince/workspace/onnx-model`.

## Native SDK Packaging

The repository currently has no checked-in or released Apple XCFrameworks. The local
SDK must therefore be built from its pinned ONNX Runtime GenAI source:

1. `scripts/fetch_onnxruntime_genai.sh` stages commit
   `9d336e4db4e49eeceda909517b882c0d73cc6c86`.
2. `scripts/build_apple.sh --build-type Release` builds device and simulator
   XCFramework slices.
3. The two resulting frameworks are copied into
   `bindings/flutter/ios/Frameworks/`, matching the existing podspec and release
   workflow:
   - `FoundryLocalMobile.xcframework`
   - `onnxruntime-genai.xcframework`

The iOS runner targets iOS 15 or newer and uses the existing Flutter plugin path
dependency. Xcode automatic signing selects a locally configured development team for
the sample bundle identifier; no signing identity or provisioning profile is
committed.

## Bundled Model Resolution

Flutter places declared assets under its framework bundle rather than at a stable
source-tree path. The iOS runner registers an app-specific MethodChannel that:

1. resolves
   `assets/models/qwen3_cpu_int4/genai_config.json` with Flutter's asset lookup API;
2. asks `Bundle.main` for the installed absolute path;
3. returns the parent directory to Dart.

The Dart model-locator abstraction uses this channel on iOS. Android retains the
existing `FLM_MODEL_PATH` compile-time value, so adding iOS support does not break the
current Android workflow. Each locator verifies that its result is an absolute,
non-empty directory path. The SDK then receives that directory unchanged:

```dart
await foundry.loadModel(
  modelDirectory,
  executionProvider: 'CPU',
  onProgress: handleProgress,
);
```

The model is a flat OGA directory because it has a top-level `genai_config.json`.
Explicitly selecting `CPU` makes the intended execution path visible and avoids
depending on provider defaults embedded in the model.

## Application Flow

The app uses one controller as the owner of all SDK resources:

```text
App launch
  -> resolve bundled model path
  -> FoundryLocal.create
  -> loadModel(CPU), publishing progress
  -> create ChatSession
  -> ready
  -> submit prompt
  -> append TextDelta values
  -> show CompletedDelta token counts and finish reason
```

The controller exposes immutable UI state for these phases:

- locating model;
- initializing SDK;
- loading model with progress;
- ready;
- generating;
- failed.

It serializes load and generation operations, cancels the active stream before
disposing, and releases `ChatSession`, `Model`, and `FoundryLocal` in reverse ownership
order.

## User Interface

The UI is intentionally diagnostic rather than product-oriented:

- model name, model path, execution provider, and current lifecycle phase;
- a load-progress indicator with native stage and percentage;
- prompt input prefilled with a short deterministic question;
- Send and Stop controls with phase-appropriate enablement;
- streamed response text;
- completion token counts, finish reason, elapsed time, and an event log;
- a Retry action after model-load failure.

The previous editable model-path field is removed for the bundled iOS flow. Android can
continue to use `FLM_MODEL_PATH` until a bundled Android asset locator is added in a
separate iteration.

## Error Handling

Failures remain explicit and actionable:

- missing staged assets fail the build or staging command, not inference;
- a missing installed bundle asset reports the asset key that could not be resolved;
- SDK initialization and model-load errors preserve the native error message;
- memory-budget rejection is shown as a model-load failure;
- stream errors retain the already generated text and return the UI to the ready state;
- Stop cancels the subscription and resets generation state without unloading the
  model;
- dispose waits for cancellation before releasing native handles.

There is no fallback to another model, execution provider, remote API, or success-shaped
mock response.

## Testing and Acceptance

### Automated checks

- Unit-test bundled-path parsing and invalid native channel responses.
- Unit-test controller phase transitions with a fake inference adapter.
- Widget-test initial loading, ready, generating, completed, failed, retry, and stop
  states.
- Run `flutter analyze` and `flutter test` for the example.

### Build checks

- Build the local Apple XCFrameworks.
- Build a signed iOS app for the connected physical device.
- Inspect the app bundle for all six runtime model files and both native frameworks.
- Confirm the model external-data file is approximately 1 GB rather than a Git LFS
  pointer or truncated asset.

### Physical-device acceptance

Install and launch the app on device
`00008150-000202601447801C`, wait for the model to reach the ready state, submit the
default prompt, and require:

- at least one non-empty `TextDelta`;
- a terminal `CompletedDelta`;
- no Flutter error, native exception, process crash, or unexpected network dependency.

Device logs and the app's diagnostic panel provide evidence if any stage fails.

## Out of Scope

- Android device validation or Android bundled-asset resolution;
- downloading or updating models from the app;
- CoreML or QNN model conversion;
- model catalog, cache, digest, or resumable-transfer support;
- production chat UX, persistence, analytics, or background generation;
- committing model binaries or signing credentials.
