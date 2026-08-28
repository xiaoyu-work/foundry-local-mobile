# FoundryLocalMobile XCFrameworks

The Swift Package expects two XCFrameworks in this directory:

1. `FoundryLocalMobile.xcframework` — the core C ABI library.
2. `onnxruntime-genai.xcframework` — ONNX Runtime GenAI, loaded at runtime for inference.

Build both from the repo root with `../../../scripts/build_apple.sh` (see `docs/building.md`);
the script drops the frameworks at `build/apple/`. Copy or symlink them here:

    scripts/build_apple.sh
    cp -R build/apple/FoundryLocalMobile.xcframework bindings/ios/Frameworks/
    cp -R build/apple/onnxruntime-genai.xcframework bindings/ios/Frameworks/

Or use the convenience wrapper:

    bindings/ios/scripts/build_xcframework.sh

For a published release, the SwiftPM manifest can be switched to
`.binaryTarget(name:url:checksum:)` entries and this directory is not shipped.
