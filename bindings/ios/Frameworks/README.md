# FoundryLocalMobile XCFramework

The Swift Package expects `FoundryLocalMobile.xcframework` in this directory. Build it
from the repo root with `../../../scripts/build_apple.sh` (see `docs/building.md`); the
script drops the framework at `build/apple/FoundryLocalMobile.xcframework`. Copy or
symlink it here:

    scripts/build_apple.sh
    cp -R build/apple/FoundryLocalMobile.xcframework bindings/ios/Frameworks/

For a published release, the SwiftPM manifest can be switched to a
`.binaryTarget(name:url:checksum:)` and this directory is not shipped.

