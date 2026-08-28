#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.
#
# Thin wrapper that builds FoundryLocalMobile.xcframework and installs it into
# `bindings/ios/Frameworks/` so this Swift Package's `binaryTarget` picks it up.
#
# The heavy lifting — CMake configure per Apple slice, `lipo`-ing simulator archs
# and driving `xcodebuild -create-xcframework` — lives in the top-level
# `scripts/build_apple.sh`, because Flutter and other bindings need the same
# XCFramework. This wrapper just delegates and copies.
#
# All CLI flags are forwarded to `build_apple.sh`. Try:
#   ./build_xcframework.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_BINDING_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${IOS_BINDING_DIR}/../.." && pwd)"

TOP_SCRIPT="${REPO_ROOT}/scripts/build_apple.sh"
if [ ! -x "${TOP_SCRIPT}" ]; then
    echo "error: cannot find ${TOP_SCRIPT}. This wrapper expects to run from a full repo checkout." >&2
    exit 1
fi

# Let the top-level script pick its own output root so incremental rebuilds are
# fast (it defaults to <repo>/build/apple, which survives `swift package clean`).
"${TOP_SCRIPT}" "$@"

# Install into the location Package.swift references.
SRC_XCFRAMEWORK="${REPO_ROOT}/build/apple/FoundryLocalMobile.xcframework"
DST_XCFRAMEWORK="${IOS_BINDING_DIR}/Frameworks/FoundryLocalMobile.xcframework"
SRC_OGA_XCFRAMEWORK="${REPO_ROOT}/build/apple/onnxruntime-genai.xcframework"
DST_OGA_XCFRAMEWORK="${IOS_BINDING_DIR}/Frameworks/onnxruntime-genai.xcframework"

if [ ! -d "${SRC_XCFRAMEWORK}" ]; then
    echo "error: expected ${SRC_XCFRAMEWORK} to exist after build_apple.sh" >&2
    exit 1
fi
if [ ! -d "${SRC_OGA_XCFRAMEWORK}" ]; then
    echo "error: expected ${SRC_OGA_XCFRAMEWORK} to exist after build_apple.sh" >&2
    exit 1
fi

mkdir -p "$(dirname "${DST_XCFRAMEWORK}")"
rm -rf "${DST_XCFRAMEWORK}"
cp -R "${SRC_XCFRAMEWORK}" "${DST_XCFRAMEWORK}"
echo "==> installed ${DST_XCFRAMEWORK}"

rm -rf "${DST_OGA_XCFRAMEWORK}"
cp -R "${SRC_OGA_XCFRAMEWORK}" "${DST_OGA_XCFRAMEWORK}"
echo "==> installed ${DST_OGA_XCFRAMEWORK}"
