#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.
#
# Build FoundryLocalCore.xcframework from the C++ core in `core/`.
#
# The XCFramework contains one `.framework` bundle per Apple platform slice:
#   * ios-arm64                 — physical iOS/iPadOS/visionOS devices
#   * ios-arm64_x86_64-simulator — iOS Simulator (Apple Silicon and Intel Macs)
#   * macos-arm64_x86_64        — macOS
#
# Each slice is a proper `.framework` with:
#   * A dynamically-linked binary (the compiled core).
#   * `Headers/` containing the three public headers plus an umbrella.
#   * `Modules/module.modulemap` so Swift resolves `import FoundryLocalCore`.
#   * A minimal `Info.plist`.
#
# The core's own `CMakeLists.txt` sets `FRAMEWORK TRUE` on Apple, but does not add
# `PUBLIC_HEADER` entries. We can't edit `core/`, so we produce the frameworks
# ourselves: build a static archive per slice, then hand-assemble the bundle.
#
# Usage:
#   ./scripts/build_xcframework.sh                    # all slices, into Frameworks/
#   FLM_SKIP_MACOS=1 ./scripts/build_xcframework.sh   # iOS + iOS Simulator only
#
# Prerequisites:
#   * Xcode 15+ (`xcodebuild`, `cmake`, `plutil`).
#   * CMake 3.22+.
#   * A checkout of Foundry Local (headers) at either
#     `../third_party/foundry-local/include` or via `FLM_FOUNDRY_LOCAL_INCLUDE_DIR`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_BINDING_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${IOS_BINDING_DIR}/../.." && pwd)"
CORE_DIR="${REPO_ROOT}/core"

FRAMEWORK_NAME="FoundryLocalCore"
FRAMEWORK_BUNDLE_ID="com.microsoft.ai.foundry.local.core"
FRAMEWORK_VERSION="0.1.0"

BUILD_ROOT="${IOS_BINDING_DIR}/build/xcframework"
OUTPUT_XCFRAMEWORK="${IOS_BINDING_DIR}/Frameworks/${FRAMEWORK_NAME}.xcframework"

MIN_IOS="15.0"
MIN_MACOS="12.0"
MIN_VISIONOS="1.0"

# Detect optional overrides.
: "${FLM_FOUNDRY_LOCAL_INCLUDE_DIR:=}"
: "${FLM_SKIP_MACOS:=0}"
: "${FLM_SKIP_VISIONOS:=1}"   # off by default; visionOS toolchain is not always present

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "error: xcodebuild is required but not found (Xcode is not installed?)." >&2
    exit 1
fi
if ! command -v cmake >/dev/null 2>&1; then
    echo "error: cmake is required but not found." >&2
    exit 1
fi

if [ -z "${FLM_FOUNDRY_LOCAL_INCLUDE_DIR}" ]; then
    for candidate in \
        "${REPO_ROOT}/third_party/foundry-local/include" \
        "${REPO_ROOT}/../foundry-local/sdk_v2/cpp/include"; do
        if [ -f "${candidate}/foundry_local/foundry_local_c.h" ]; then
            FLM_FOUNDRY_LOCAL_INCLUDE_DIR="${candidate}"
            break
        fi
    done
fi
if [ -z "${FLM_FOUNDRY_LOCAL_INCLUDE_DIR}" ] || [ ! -f "${FLM_FOUNDRY_LOCAL_INCLUDE_DIR}/foundry_local/foundry_local_c.h" ]; then
    echo "error: cannot locate Foundry Local headers. Set FLM_FOUNDRY_LOCAL_INCLUDE_DIR." >&2
    exit 1
fi

rm -rf "${BUILD_ROOT}" "${OUTPUT_XCFRAMEWORK}"
mkdir -p "${BUILD_ROOT}" "$(dirname "${OUTPUT_XCFRAMEWORK}")"

# -----------------------------------------------------------------------------
# Build a single static-library slice with CMake, using the appropriate SDK.
# Args: name, cmake_system_name, cmake_osx_sysroot, cmake_osx_architectures, deployment_target_flag
build_slice() {
    local slice="$1"
    local system_name="$2"
    local sysroot="$3"
    local archs="$4"
    local deployment_flag="$5"

    local slice_dir="${BUILD_ROOT}/${slice}"
    local cmake_dir="${slice_dir}/cmake"
    mkdir -p "${cmake_dir}"

    echo "==> Configuring ${slice} (archs=${archs}, sysroot=${sysroot})"
    cmake -S "${CORE_DIR}" -B "${cmake_dir}" \
        -G "Xcode" \
        -DCMAKE_SYSTEM_NAME="${system_name}" \
        -DCMAKE_OSX_SYSROOT="${sysroot}" \
        -DCMAKE_OSX_ARCHITECTURES="${archs}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DFLM_BUILD_SHARED=OFF \
        -DFLM_FOUNDRY_LOCAL_INCLUDE_DIR="${FLM_FOUNDRY_LOCAL_INCLUDE_DIR}" \
        ${deployment_flag} \
        -DCMAKE_C_VISIBILITY_PRESET=hidden \
        -DCMAKE_CXX_VISIBILITY_PRESET=hidden \
        > "${slice_dir}/cmake_configure.log" 2>&1 || {
            echo "error: cmake configure failed for ${slice}. See ${slice_dir}/cmake_configure.log" >&2
            exit 1
        }

    echo "==> Building ${slice}"
    cmake --build "${cmake_dir}" --config Release --target foundry_local_mobile \
        > "${slice_dir}/cmake_build.log" 2>&1 || {
            echo "error: cmake build failed for ${slice}. See ${slice_dir}/cmake_build.log" >&2
            exit 1
        }

    # CMake with the Xcode generator writes archives under Release-<sdk>/.
    local built_archive
    built_archive="$(find "${cmake_dir}" -name 'libfoundry_local_mobile*.a' | head -n1)"
    if [ -z "${built_archive}" ] || [ ! -f "${built_archive}" ]; then
        echo "error: could not locate built static archive for ${slice} under ${cmake_dir}" >&2
        exit 1
    fi

    assemble_framework "${slice}" "${built_archive}" "${sysroot}"
}

# Assemble a `.framework` bundle from a compiled static archive. We ship the framework
# with a static Mach-O binary so the app doesn't have to embed a separate dylib and
# the core's `dlopen` of libfoundry_local still works (dlopen doesn't care whether the
# caller is static or dynamic).
assemble_framework() {
    local slice="$1"
    local archive="$2"
    local sysroot="$3"
    local framework_dir="${BUILD_ROOT}/${slice}/${FRAMEWORK_NAME}.framework"

    mkdir -p "${framework_dir}/Headers" "${framework_dir}/Modules"

    # Copy the public headers as-is so #include paths continue to work.
    cp "${CORE_DIR}/include/foundry_local_mobile/flm_export.h" "${framework_dir}/Headers/"
    cp "${CORE_DIR}/include/foundry_local_mobile/flm_types.h"  "${framework_dir}/Headers/"
    cp "${CORE_DIR}/include/foundry_local_mobile/flm_api.h"    "${framework_dir}/Headers/"

    # Umbrella header: pulls in the whole public surface. The `#include` paths use
    # angle brackets and the framework name so Swift finds them via the module map.
    cat >"${framework_dir}/Headers/${FRAMEWORK_NAME}.h" <<'HEADER'
// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Umbrella header for the FoundryLocalCore framework. Included transitively by the
// `flm_api.h` header and by Swift when it `import FoundryLocalCore`s.

#ifndef FOUNDRY_LOCAL_CORE_UMBRELLA_H
#define FOUNDRY_LOCAL_CORE_UMBRELLA_H

#include <FoundryLocalCore/flm_export.h>
#include <FoundryLocalCore/flm_types.h>
#include <FoundryLocalCore/flm_api.h>

#endif
HEADER

    # Module map — this is what makes `import FoundryLocalCore` work in Swift.
    cat >"${framework_dir}/Modules/module.modulemap" <<MODULEMAP
framework module ${FRAMEWORK_NAME} {
    umbrella header "${FRAMEWORK_NAME}.h"
    export *
    module * { export * }
}
MODULEMAP

    # Info.plist. Written as XML for readability; xcodebuild is happy with either.
    cat >"${framework_dir}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>${FRAMEWORK_NAME}</string>
    <key>CFBundleIdentifier</key><string>${FRAMEWORK_BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${FRAMEWORK_NAME}</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>${FRAMEWORK_VERSION}</string>
    <key>CFBundleVersion</key><string>${FRAMEWORK_VERSION}</string>
</dict>
</plist>
PLIST

    # Copy the compiled archive as the framework's binary. `xcodebuild
    # -create-xcframework` accepts a `.framework` whose binary is a static Mach-O.
    cp "${archive}" "${framework_dir}/${FRAMEWORK_NAME}"
}

# -----------------------------------------------------------------------------
# Slices

build_slice "ios-device" "iOS" "iphoneos" "arm64" "-DCMAKE_OSX_DEPLOYMENT_TARGET=${MIN_IOS}"
build_slice "ios-simulator" "iOS" "iphonesimulator" "arm64;x86_64" "-DCMAKE_OSX_DEPLOYMENT_TARGET=${MIN_IOS}"

XCFRAMEWORK_ARGS=(
    -framework "${BUILD_ROOT}/ios-device/${FRAMEWORK_NAME}.framework"
    -framework "${BUILD_ROOT}/ios-simulator/${FRAMEWORK_NAME}.framework"
)

if [ "${FLM_SKIP_MACOS}" != "1" ]; then
    build_slice "macos" "Darwin" "macosx" "arm64;x86_64" "-DCMAKE_OSX_DEPLOYMENT_TARGET=${MIN_MACOS}"
    XCFRAMEWORK_ARGS+=( -framework "${BUILD_ROOT}/macos/${FRAMEWORK_NAME}.framework" )
fi

if [ "${FLM_SKIP_VISIONOS}" != "1" ]; then
    build_slice "visionos-device" "visionOS" "xros" "arm64" "-DCMAKE_OSX_DEPLOYMENT_TARGET=${MIN_VISIONOS}"
    build_slice "visionos-simulator" "visionOS" "xrsimulator" "arm64" "-DCMAKE_OSX_DEPLOYMENT_TARGET=${MIN_VISIONOS}"
    XCFRAMEWORK_ARGS+=(
        -framework "${BUILD_ROOT}/visionos-device/${FRAMEWORK_NAME}.framework"
        -framework "${BUILD_ROOT}/visionos-simulator/${FRAMEWORK_NAME}.framework"
    )
fi

echo "==> Assembling ${OUTPUT_XCFRAMEWORK}"
xcodebuild -create-xcframework "${XCFRAMEWORK_ARGS[@]}" -output "${OUTPUT_XCFRAMEWORK}"

# Sanity check: the XCFramework must contain a module map per slice so Swift can
# import it. `xcodebuild -create-xcframework` copies these verbatim, but if the
# framework we handed in was missing one, we would end up with an XCFramework that
# Swift refuses to consume — better to fail loudly here than at `swift build`.
for slice_dir in "${OUTPUT_XCFRAMEWORK}"/*; do
    [ -d "${slice_dir}" ] || continue
    module_map="${slice_dir}/${FRAMEWORK_NAME}.framework/Modules/module.modulemap"
    if [ ! -f "${module_map}" ]; then
        echo "error: ${module_map} missing — Swift will not be able to import the module." >&2
        exit 1
    fi
done

echo "==> Done: ${OUTPUT_XCFRAMEWORK}"
