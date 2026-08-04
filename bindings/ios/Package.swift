// swift-tools-version:5.9
// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import PackageDescription

// The native core ships as an XCFramework. Build it locally with
// `scripts/build_apple.sh` at the repo root (which invokes CMake +
// `xcodebuild -create-xcframework` and drops the result at
// `build/apple/FoundryLocalMobile.xcframework`); then copy or symlink it into
// `Frameworks/`. Once releases attach a prebuilt artefact, replace the local
// `binaryTarget` below with `.binaryTarget(name:url:checksum:)`.
//
// The XCFramework contains a proper `.framework` bundle per slice with an umbrella
// header and a module map, so `import FoundryLocalMobile` resolves the flat C ABI
// in Swift without a bridging header.

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
            name: "FoundryLocalMobile",
            path: "Frameworks/FoundryLocalMobile.xcframework"
        ),
        .target(
            name: "FoundryLocal",
            dependencies: ["FoundryLocalMobile"],
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
