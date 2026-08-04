// swift-tools-version:5.9
// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import PackageDescription

// The native core ships as an XCFramework. Build it locally with
// `scripts/build_xcframework.sh` (which invokes CMake + `xcodebuild -create-xcframework`
// and drops the result into `Frameworks/`), or replace the local binaryTarget below
// with a `.binaryTarget(name:url:checksum:)` pointing at a published release artifact
// once one is available.
//
// The XCFramework contains a proper `.framework` bundle per slice with an umbrella
// header and a module map, so `import FoundryLocalCore` resolves the flat C ABI in
// Swift without a bridging header.

let package = Package(
    name: "FoundryLocal",
    platforms: [
        .iOS(.v15),
        .macCatalyst(.v15),
        .macOS(.v12),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "FoundryLocal", targets: ["FoundryLocal"]),
    ],
    targets: [
        .binaryTarget(
            name: "FoundryLocalCore",
            path: "Frameworks/FoundryLocalCore.xcframework"
        ),
        .target(
            name: "FoundryLocal",
            dependencies: ["FoundryLocalCore"],
            path: "Sources/FoundryLocal",
            swiftSettings: [
                // Swift 6 strict-concurrency cleanliness is a first-class goal for this
                // SDK: the C callbacks fire on core job-pool threads and every Swift
                // wrapper has to be crossing-thread-safe. Enabling the checks under
                // Swift 5 tooling catches regressions before Swift 6 mode is on.
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
            ]
        ),
    ]
)
