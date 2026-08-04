# FoundryLocalCore XCFramework

The Swift Package expects `FoundryLocalCore.xcframework` in this directory. Build it
with `../scripts/build_xcframework.sh`.

For a published release, the SwiftPM manifest can be switched to a
`.binaryTarget(name:url:checksum:)` and this directory is not shipped.
