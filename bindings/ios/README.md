# FoundryLocal for iOS, iPadOS, macOS, and visionOS

Swift SDK for [Microsoft Foundry Local](https://github.com/microsoft/Foundry-Local),
a runtime for on-device inference against ONNX Runtime models.

The package wraps the flat C ABI in `core/` behind an idiomatic Swift API — async /
await for one-shot calls, `AsyncThrowingStream` for streaming inference, `Codable`
for every JSON payload, plus a `URLSession`-based transport that keeps multi-gigabyte
model downloads running while the app is backgrounded or killed.

- iOS 15 · iPadOS 15 · Mac Catalyst 15 · macOS 12 · visionOS 1
- Swift 5.9+, Xcode 15+
- Swift 6 strict-concurrency clean

---

## Contents

1. [Installation](#installation)
2. [Building the XCFramework](#building-the-xcframework)
3. [Quick start](#quick-start)
4. [Model sources](#model-sources)
5. [Background downloads and AppDelegate wiring](#background-downloads-and-appdelegate-wiring)
6. [Custom HTTP transport](#custom-http-transport)
7. [Lifecycle wiring](#lifecycle-wiring)
8. [Bundled models](#bundled-models)
9. [Logging](#logging)
10. [Error handling](#error-handling)
11. [Threading model](#threading-model)
12. [What's not here](#whats-not-here)

---

## Installation

### Swift Package Manager

```swift
// Package.swift
.package(url: "https://github.com/microsoft/foundry-local-mobile", from: "0.1.0")
```

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "FoundryLocal", package: "foundry-local-mobile"),
    ]
)
```

`FoundryLocal` depends on an XCFramework named `FoundryLocalMobile` that ships alongside
this package under `Frameworks/FoundryLocalMobile.xcframework`. Published releases attach
a pre-built XCFramework to the GitHub release. For local development, build it
yourself as described in [Building the XCFramework](#building-the-xcframework).

### CocoaPods

Not shipped in the first release. If enough apps are pinned to CocoaPods we will add a
podspec that mirrors this package.

## Building the XCFramework

From the repository root:

```bash
./scripts/build_apple.sh
cp -R build/apple/FoundryLocalMobile.xcframework bindings/ios/Frameworks/
```

Or, from inside `bindings/ios/`, use the wrapper that does the copy for you:

```bash
./scripts/build_xcframework.sh
```

The top-level `scripts/build_apple.sh`:

- Builds the C++ core with CMake for iOS device (`arm64`) and iOS simulator
  (`arm64` and `x86_64`, fused into a single Mach-O with `lipo`). Pass `--macos` to
  add a macOS slice.
- Wraps each build in a `.framework` bundle with a public umbrella header (`flm_api.h`)
  and a module map, so Swift resolves `import FoundryLocalMobile` without a bridging
  header.
- Combines the slices with `xcodebuild -create-xcframework` into
  `build/apple/FoundryLocalMobile.xcframework`. The wrapper above copies it into
  `bindings/ios/Frameworks/` where `Package.swift` references it.

Requirements:

- Xcode 15+ (`xcodebuild` on `PATH`).
- CMake 3.22+.
- Foundry Local's own header tree, either at
  `third_party/foundry-local/include` or via the `FLM_FOUNDRY_LOCAL_INCLUDE_DIR`
  environment variable.

The runtime library itself is **not** bundled. The core loads it dynamically with
`dlopen`, so you either link Foundry Local as a dependency of your app or ship the
runtime alongside your build; see the root README for the two-flavour distribution.

## Quick start

```swift
import FoundryLocal

let sdk = try FoundryLocal(config: FoundryLocalConfig(appName: "Notes"))

// 1. Acquire the model. Ship it in the app bundle (a folder reference) or point at
//    a URL you host. `addModelSource` returns a result carrying — in the common
//    case — a ready-to-use `model` handle minted inside the same job.
let added = try await sdk.addModelSource(
    .remote(
        name: "qwen2.5-0.5b",
        url: URL(string: "https://models.example.com/qwen2.5-0.5b/manifest.json")!
    )
) { p in
    print("\(p.percent)% — \(p.stage)")
}

// `added.model` is `nil` only in the rare case where the transfer succeeded but
// the local catalog scan did not pick up the freshly-installed files — the model
// *is* on disk at `added.path`, so recover with a catalog lookup by name rather
// than treating it as an error.
let model = try await added.model ?? sdk.catalog.model(alias: added.name)

// 2. Load into memory (best EP chosen by default). No network work happens here.
try await model.load()

// 3. Chat.
let chat = try model.createChatSession()
for try await delta in chat.completeStreaming("Explain vector databases in one line.") {
    print(delta.text, terminator: "")
}
```

`delta.text` is empty for the non-text events (reasoning traces, tool calls,
usage counters, terminal marker), so a typewriter UI can concatenate blindly.
Pattern-match on the `ChatDelta` case itself when you need to react to
reasoning or handle a tool call.

For a model package (a manifest with several device-specific variants) attach the
policy to the source itself — the runtime picks the winning variant against the
manifest and only fetches that one:

```swift
let added = try await sdk.addModelSource(
    .remote(
        name: "phi-4-mini",
        url: URL(string: "https://models.example.com/phi-4-mini/manifest.json")!,
        constraints: VariantConstraints(
            maxDownloadBytes: 800 * 1024 * 1024,
            allowedDevices: [.npu, .gpu, .cpu]
        )
    )
)
let model = try await added.model ?? sdk.catalog.model(alias: added.name)
print("picked variant \(added.variantId ?? "n/a")")
try await model.load()

// After the fact, inspect what was picked or reselect against fresh constraints:
let variants = try model.variants()
print("selected \(variants.selectedVariantId ?? "?") from \(variants.variants.count) options")

let alternate = try model.selectBestVariant(
    VariantConstraints(preferSmallest: true)
)
```

Non-streaming call:

```swift
let reply = try await chat.complete("Summarise this note in three words: \(note)")
print(reply.text ?? "")
```

The `sdk.catalog` surface (list, filter, look up by alias, cache stats) is still
there — it just describes what's already on the device. Acquisition is
`addModelSource` only; see [Model sources](#model-sources) for both flavours.

## Model sources

Two shapes, both resolving to a directory the runtime can load. See
[`docs/model-sources.md`](../../docs/model-sources.md) for the wire format.

### Remote

```swift
let added = try await sdk.addModelSource(
    .remote(
        name: "my-fine-tune",
        url: URL(string: "https://models.example.com/my-fine-tune/manifest.json")!,
        headers: ["Authorization": "Bearer \(token)"]
    )
) { p in
    print("[\(p.stage)] \(p.percent)%")
}
let model = try await added.model ?? sdk.catalog.model(alias: added.name)
```

`added` also carries `variantId`, `bytesDownloaded`, `bytesReused`, `wasCached`
and `path` — surface `bytesDownloaded + bytesReused` in a "downloaded X MB"
UI, or hand `path` to your own file inspector.

The URL must point at a manifest — a Foundry model package `manifest.json` or a flat
`model.json` file index. The SDK follows relative asset URLs against the manifest's
base.

Both `resume` and `verifyChecksums` default to `true`. Override them per source
when you need to force a full redownload (`resume: false`) or trust your storage
to enforce integrity another way (`verifyChecksums: false`):

```swift
.remote(
    name: "my-fine-tune",
    url: url,
    headers: ["Authorization": "******"],
    resume: false,          // start every restart from byte 0
    verifyChecksums: true   // still SHA-256 every file after download
)
```

### Variant constraints

`VariantConstraints` is the cross-platform, declarative way to pick a package
variant **before** any weights are transferred. Only these four fields
round-trip through the ABI:

| Field              | Meaning                                                                                     |
| ------------------ | ------------------------------------------------------------------------------------------- |
| `maxDownloadBytes` | Skip variants whose transfer would exceed this many bytes. `nil` = no limit.                |
| `allowedDevices`   | Consider only variants for these devices. Empty = any device.                               |
| `preferSmallest`   | Break ties on smallest transfer instead of highest compatibility score.                     |
| `requireCached`    | Consider only variants already on disk. Useful for an offline reselect that must not fetch. |

`ModelSource.remote` and `.bundled` both accept a `constraints:` argument. The same
type feeds `Model.selectBestVariant` for after-the-fact reselection over an
already-installed package (say the device situation changed and the app wants to
switch tiers without redownloading).

### Bundled

For a model shipped inside the app bundle as a folder reference (see
[Bundled models](#bundled-models)):

```swift
let source = try ModelSource.bundled(
    name: "phi-4-mini",
    folder: "phi-4-mini",
    in: .main,
    subdirectory: "models"
)
let added = try await sdk.addModelSource(source)
let model = try await added.model ?? sdk.catalog.model(alias: added.name)
```

## Background downloads and AppDelegate wiring

The default transport is `URLSessionBackgroundTransport`, which hands transfers to the
system `nsurlsessiond`. Downloads survive:

- The app being backgrounded or the screen being locked.
- The app being killed by the user or the system — iOS relaunches the app in the
  background to deliver completed downloads.

For that relaunch to work, the app **must** forward
`application(_:handleEventsForBackgroundURLSessionWithIdentifier:completionHandler:)`
to `URLSessionBackgroundTransport.registerBackgroundCompletionHandler(_:for:)`:

```swift
// UIKit AppDelegate
func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
) {
    URLSessionBackgroundTransport.registerBackgroundCompletionHandler(
        completionHandler, for: identifier
    )
}
```

Under SwiftUI, wire the same call from a `UIApplicationDelegateAdaptor`:

```swift
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        URLSessionBackgroundTransport.registerBackgroundCompletionHandler(
            completionHandler, for: identifier
        )
    }
}

@main
struct MyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { WindowGroup { ContentView() } }
}
```

The default session identifier is
`"<bundle-id>.foundrylocal.<app-name>.downloads"`; construct a
`URLSessionBackgroundTransport(identifier:)` and install it yourself if you need a
different one.

### Metered / cellular

The SDK observes `NWPathMonitor` and forwards metered / unmetered transitions to
the core, which pauses and resumes in-flight downloads according to
`FoundryLocalConfig.downloadOnMeteredNetwork`. Set it up-front when constructing
the `FoundryLocalConfig`; the SDK does not currently expose a per-source
override.

## Custom HTTP transport

Implement `HTTPTransport` for certificate pinning, an in-house download queue or a
custom authentication flow, and install it before creating `FoundryLocal`:

```swift
final class PinnedTransport: HTTPTransport, @unchecked Sendable {
    func send(_ request: HTTPRequest) -> Bool {
        // Kick off your own URLSession / Alamofire / Nio download task.
        // MUST return immediately.
        // MUST eventually call TransportReport.complete(id:...), exactly once.
        return true
    }
    func cancel(requestId: UInt64) { /* cancel in-flight task */ }
}

TransportRegistry.install(PinnedTransport())
let sdk = try FoundryLocal(config: ...)  // will not install its own transport
```

Contract:

- `send` must return without blocking. Any I/O runs on your own queue.
- `TransportReport.complete(id:...)` **must** be called exactly once per request,
  even on cancellation or failure. The core blocks a job thread waiting for it.
- Report body bytes via `TransportReport.body(id:...)` **only** when the request's
  `destinationPath` is `nil`. Otherwise, write bytes to that file yourself.
- Honour `HTTPRequest.offset`: when > 0, send a `Range: bytes=<offset>-` header and
  append to the destination file instead of truncating it.

## Lifecycle wiring

Automatic. `FoundryLocal` observes:

| Signal                                                | Forwarded event                             |
| ----------------------------------------------------- | ------------------------------------------- |
| `UIApplication.didBecomeActiveNotification`           | `FLM_LIFECYCLE_FOREGROUND`                  |
| `UIApplication.didEnterBackgroundNotification`        | `FLM_LIFECYCLE_BACKGROUND`                  |
| `UIApplication.didReceiveMemoryWarningNotification`   | `FLM_LIFECYCLE_MEMORY_WARNING`              |
| `ProcessInfo.thermalStateDidChangeNotification` (.serious / .critical) | `FLM_LIFECYCLE_THERMAL_THROTTLING` |
| `.NSProcessInfoPowerStateDidChange` (low-power on)    | `FLM_LIFECYCLE_LOW_POWER`                   |
| `NWPathMonitor` (`isExpensive`/`isConstrained`)       | `FLM_LIFECYCLE_NETWORK_METERED` / `_UNMETERED` |

Manually push an event when you have an app-internal signal that's more specific:

```swift
sdk.notify(lifecycle: .memoryCritical)
```

## Bundled models

`Bundle.main` on iOS resolves resources to real filesystem paths (unlike Android's
compressed asset stream), so a directory of ONNX and metadata files shipped inside
the `.app` can be loaded in place — no unpack step.

The catch is that Xcode has two ways to reference a directory in a target:

- **Group** (yellow folder): Xcode flattens the group's files into the resource root.
  Sub-directories are lost. Do not use this for a model directory.
- **Folder reference** (blue folder): the directory is copied verbatim into the app
  bundle, preserving its structure. **This is what the runtime needs.**

To convert a group into a folder reference in Xcode: delete the group (**Remove
Reference**, not **Move to Trash**), then drag the folder back in with **Create folder
references** selected. The icon should turn blue.

The bundled path is stable across the app's lifetime; downloading is not required.

## Logging

By default, ABI log messages go to `os_log`. Install a custom sink to route them
elsewhere:

```swift
FoundryLocalLog.install { level, tag, message in
    logger.log(level: level.rawValue, tag: tag, message: message)
}

try FoundryLocal.setLogLevel(.debug)
```

## Error handling

Every call throws `FoundryLocalError`. Discriminate on `.code`, and consult
`.detail` for the machine-readable JSON the ABI attaches (retry hints, offending model
id, HTTP status). `error.isRetryable` returns `true` for transient failures worth
another shot without any change to inputs.

```swift
do {
    _ = try await model.load()
} catch let error as FoundryLocalError where error.code == .memoryPressure {
    // The core unloaded models under pressure. Retry after unloading anything else
    // the app was keeping around.
} catch let error as FoundryLocalError where error.isRetryable {
    try await Task.sleep(nanoseconds: 500_000_000)
    _ = try await model.load()
}
```

## Threading model

The C ABI is thread-safe; the Swift wrappers hold the underlying handle and are
`@unchecked Sendable`. Callbacks (progress, delta, completion) fire on core job-pool
threads and are bridged to Swift Tasks / `AsyncThrowingStream`s without hopping to a
specific queue — receive them from your `Task` and dispatch to the main actor when you
need to update UI.

`Task` cancellation is wired to `flm_job_cancel`:

```swift
let task = Task {
    for try await delta in chat.completeStreaming(prompt) { ... }
}
task.cancel()  // triggers flm_job_cancel; the stream finishes cleanly
```

Handles are released automatically on `deinit`, but call `close()` when you are done
with a session to free the KV cache immediately — ARC on iOS is deterministic but
sessions can be large.

## What's not here

- **A test suite.** The core is exercised elsewhere.
- **A shipped Foundry Local runtime.** The core `dlopen`s
  `libfoundry_local`; ship it alongside your app per the root README.
- **A CocoaPods podspec.** Add one if your organisation is Pods-only.
- **Downloads from the Foundry Local desktop catalogue.** That catalogue publishes
  desktop CUDA / DirectML / OpenVINO / x64 builds, which are useless on a phone.
  `flm_model_download_async` now returns `FLM_ERROR_NOT_IMPLEMENTED` for anything
  not already on the device — the `Model.download()` idiomatic call is gone with
  it. Ship your model, or host it under a URL your app can reach, and add it as a
  [model source](#model-sources).
