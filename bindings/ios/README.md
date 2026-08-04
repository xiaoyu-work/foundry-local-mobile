# FoundryLocal for iOS, iPadOS, macOS, and visionOS

Swift SDK for [Microsoft Foundry Local](https://github.com/microsoft/Foundry-Local),
a runtime for on-device inference against ONNX Runtime models.

The package wraps the flat C ABI in `core/` behind an idiomatic Swift API — async /
await for one-shot calls, `AsyncThrowingStream` for streaming inference and downloads,
`Codable` for every JSON payload, plus a `URLSession`-based transport that keeps
multi-gigabyte model downloads running while the app is backgrounded or killed.

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

// 1. Ask the catalog for a model. This is a metadata read; nothing is downloaded yet.
let model = try await sdk.catalog.model(alias: "qwen2.5-0.5b")

// 2. Download it, in the foreground or the background. Progress is streamed.
for try await progress in model.download() {
    print("\(progress.percent)% — \(progress.stage)")
}

// 3. Load into memory (chooses the best execution provider by default).
try await model.load()

// 4. Chat.
let chat = try model.createChatSession()
for try await delta in chat.completeStreaming("Explain vector databases in one line.") {
    if case .text(let fragment) = delta { print(fragment, terminator: "") }
}
```

For a model package (a manifest with several device-specific variants) select a
variant first:

```swift
let package = try await sdk.catalog.model(alias: "phi-4-mini")
let bestVariantId = try package.selectBestVariant()
print("selected \(bestVariantId)")
for try await _ in package.download() {}
try await package.load()
```

Non-streaming call:

```swift
let reply = try await chat.complete("Summarise this note in three words: \(note)")
print(reply.text ?? "")
```

## Model sources

Two shapes, both resolving to a directory the runtime can load. See
[`docs/model-sources.md`](../../docs/model-sources.md) for the wire format.

### Remote

```swift
let result = try await sdk.addModelSource(
    .remote(
        name: "my-fine-tune",
        url: URL(string: "https://models.example.com/my-fine-tune/model.json")!,
        headers: ["Authorization": "Bearer \(token)"]
    ),
    progress: { p in print("[\(p.stage)] \(p.percent)%") }
)
let model = try await sdk.catalog.model(alias: result.name)
```

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
_ = try await sdk.addModelSource(source)
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

The SDK observes `NWPathMonitor` and forwards metered / unmetered transitions to the
core, which pauses and resumes downloads according to
`FoundryLocalConfig.downloadOnMeteredNetwork`. Override per-download:

```swift
for try await _ in model.download(allowMetered: false) {}
```

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
    for try await progress in model.download() { ... }
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
