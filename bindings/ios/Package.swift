// swift-tools-version:5.9
// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import PackageDescription

// The native core ships as two XCFrameworks:
//
//   1. FoundryLocalMobile.xcframework — the core C ABI library.
//   2. onnxruntime-genai.xcframework — ONNX Runtime GenAI, which the core
//      loads at runtime for model inference.
//
// Build both locally with `scripts/build_apple.sh` at the repo root (which
// invokes CMake + `xcodebuild -create-xcframework` and drops the results at
// `build/apple/`); then copy or symlink them into `Frameworks/`. Once releases
// attach prebuilt artefacts, replace the local `binaryTarget` entries below
// with `.binaryTarget(name:url:checksum:)`.

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
        .binaryTarget(
            name: "OnnxRuntimeGenAI",
            path: "Frameworks/onnxruntime-genai.xcframework"
        ),
        .target(
            name: "FoundryLocal",
            dependencies: ["FoundryLocalMobile", "OnnxRuntimeGenAI"],
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
