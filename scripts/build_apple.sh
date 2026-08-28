#!/usr/bin/env bash
# Build the mobile core for Apple platforms and combine the per-slice frameworks
# into XCFrameworks the iOS binding can consume directly.
#
# Two XCFrameworks are produced:
#
#   <output>/FoundryLocalMobile.xcframework/
#     ios-arm64/FoundryLocalMobile.framework/
#     ios-arm64_x86_64-simulator/FoundryLocalMobile.framework/
#     [macos-arm64_x86_64/FoundryLocalMobile.framework/]  (only with --macos)
#
#   <output>/onnxruntime-genai.xcframework/
#     ios-arm64/onnxruntime-genai.framework/
#     ios-arm64_x86_64-simulator/onnxruntime-genai.framework/
#     [macos-arm64_x86_64/onnxruntime-genai.framework/]  (only with --macos)
#
# FoundryLocalMobile links against onnxruntime-genai at runtime; both must be
# shipped together. ONNX Runtime is linked/embedded inside OGA's framework
# according to OGA's official Apple build setup (static on iOS, dylib on macOS).
#
# `lipo` fuses the two simulator arches into one framework binary before
# xcodebuild -create-xcframework runs, because -create-xcframework refuses to
# accept two frameworks that share the same platform+variant tag.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FRAMEWORK_NAME="FoundryLocalMobile"
BUILD_TYPE="Release"
OUTPUT_DIR="${REPO_ROOT}/build/apple"
INCLUDE_MACOS=0
IOS_DEPLOYMENT_TARGET="15.0"
MACOS_DEPLOYMENT_TARGET="12.0"
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
CLEAN=0
VERBOSE=0

usage() {
    cat <<EOF
${SCRIPT_NAME} — build the core as an Apple XCFramework

Usage:
  ${SCRIPT_NAME} [options]

Options:
  --output <path>       Output root. Default: <repo>/build/apple.
                        The XCFramework lands at <output>/${FRAMEWORK_NAME}.xcframework.
  --build-type <type>   CMake build type. Default: ${BUILD_TYPE}.
  --ios-min <ver>       iOS deployment target. Default: ${IOS_DEPLOYMENT_TARGET}.
  --macos-min <ver>     macOS deployment target. Default: ${MACOS_DEPLOYMENT_TARGET}.
  --macos               Also build a macos-arm64_x86_64 slice.
  --clean               Remove <output> before building.
  --jobs <n>            Parallel build jobs. Default: detected CPU count.
  --verbose             Show every command.
  -h, --help            This help.

Requires:
  * macOS host with a full Xcode install (xcodebuild must be able to find the
    iPhoneOS and iPhoneSimulator SDKs).
  * cmake, lipo (both included with the Xcode command line tools).

Exit status:
  0  XCFramework produced
  1  build failed
  2  a prerequisite is missing or host is not macOS
EOF
}

# Progress goes to stderr, not stdout: build_slice returns the framework path
# on stdout, and anything else printed there is captured as part of that path.
log()  { printf '[apple] %s\n' "$*" >&2; }
warn() { printf '[apple] warn: %s\n' "$*" >&2; }
die()  { printf '[apple] error: %s\n' "$1" >&2; exit "${2:-1}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)         OUTPUT_DIR="$2"; shift 2 ;;
        --output=*)       OUTPUT_DIR="${1#*=}"; shift ;;
        --build-type)     BUILD_TYPE="$2"; shift 2 ;;
        --build-type=*)   BUILD_TYPE="${1#*=}"; shift ;;
        --ios-min)        IOS_DEPLOYMENT_TARGET="$2"; shift 2 ;;
        --ios-min=*)      IOS_DEPLOYMENT_TARGET="${1#*=}"; shift ;;
        --macos-min)      MACOS_DEPLOYMENT_TARGET="$2"; shift 2 ;;
        --macos-min=*)    MACOS_DEPLOYMENT_TARGET="${1#*=}"; shift ;;
        --macos)          INCLUDE_MACOS=1; shift ;;
        --jobs)           JOBS="$2"; shift 2 ;;
        --jobs=*)         JOBS="${1#*=}"; shift ;;
        --clean)          CLEAN=1; shift ;;
        --verbose)        VERBOSE=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                die "unknown option: $1 (try --help)" ;;
    esac
done

[[ ${VERBOSE} -eq 1 ]] && set -x

if [[ "$(uname -s)" != "Darwin" ]]; then
    die "this script must run on macOS; got $(uname -s). Apple SDKs and code signing are only available there." 2
fi

for tool in cmake xcodebuild lipo xcrun; do
    command -v "${tool}" >/dev/null 2>&1 || die "${tool} is required but not on PATH" 2
done

if [[ ${CLEAN} -eq 1 && -d "${OUTPUT_DIR}" ]]; then
    log "removing ${OUTPUT_DIR}"
    rm -rf "${OUTPUT_DIR}"
fi
mkdir -p "${OUTPUT_DIR}"

# Resolve SDK paths once up front. xcrun --show-sdk-path fails loudly if the
# corresponding SDK is not installed, which is a clearer error than a CMake
# configure failure two hundred lines in.
IPHONEOS_SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
IPHONESIMULATOR_SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
if [[ ${INCLUDE_MACOS} -eq 1 ]]; then
    MACOSX_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
fi

# Build one slice through the core CMake with the correct sysroot, archs and
# deployment target, and package the output as a proper .framework alongside
# the public headers and a module map.
#
# CMake's FRAMEWORK target property does the bundle layout, but Xcode collapses
# public headers into a flat Headers/ directory, and the core's headers ship
# under foundry_local_mobile/ — flattening them breaks
# `#include "foundry_local_mobile/flm_api.h"`. So we harvest the framework CMake
# produced and re-lay the headers underneath it, which keeps includes working
# from Swift without a shim header per file.
build_slice() {
    local slice_id="$1"       # e.g. ios-arm64
    local sysroot="$2"
    local archs="$3"          # ";"-separated for CMake
    local deployment_var="$4" # CMake target-triple deployment variable
    local deployment_val="$5"
    local build_dir="${OUTPUT_DIR}/cmake/${slice_id}"
    local install_dir="${OUTPUT_DIR}/install/${slice_id}"
    local framework_dir="${install_dir}/${FRAMEWORK_NAME}.framework"

    log "configuring ${slice_id} (sysroot=$(basename "${sysroot}"), archs=${archs})"

    local -a cmake_args=(
        -S "${REPO_ROOT}/core"
        -B "${build_dir}"
        -G Xcode
        -DCMAKE_BUILD_TYPE="${BUILD_TYPE}"
        -DCMAKE_OSX_SYSROOT="${sysroot}"
        -DCMAKE_OSX_ARCHITECTURES="${archs}"
        "-D${deployment_var}=${deployment_val}"
        -DFLM_BUILD_SHARED=ON
        -DBUILD_APPLE_FRAMEWORK=ON
        # Skip CMake's compiler test — for the iOS device SDK CMake sometimes
        # cannot link a stand-alone test binary without a signing identity,
        # which fails even though the real library will build cleanly.
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
    )
    if [[ "${slice_id}" == ios-* ]]; then
        cmake_args+=(-DIOS=ON)
    else
        cmake_args+=(-DIOS=OFF)
    fi
    # Same reason as log(): keep the configure and build chatter off the
    # stdout this function returns a path on.
    cmake "${cmake_args[@]}" >&2
    cmake --build "${build_dir}" --config "${BUILD_TYPE}" --parallel "${JOBS}" >&2

    # CMake with -G Xcode puts the library under a per-config subdirectory. It
    # honours FRAMEWORK TRUE on Apple, so the artefact is already a framework;
    # we simply harvest the outermost .framework directory.
    local produced_framework
    produced_framework="$(find "${build_dir}" -type d -name "${FRAMEWORK_NAME}.framework" -print -quit || true)"
    if [[ -z "${produced_framework}" ]]; then
        # Fallback for hosts where the framework property has not applied (Ninja
        # generator, etc): the target is a plain .dylib we wrap ourselves.
        local dylib
        dylib="$(find "${build_dir}" -type f -name "lib${FRAMEWORK_NAME}.dylib" -print -quit || true)"
        [[ -n "${dylib}" ]] || die "no ${FRAMEWORK_NAME}.framework or lib${FRAMEWORK_NAME}.dylib produced for ${slice_id}"
        rm -rf "${framework_dir}"
        mkdir -p "${framework_dir}/Headers"
        cp "${dylib}" "${framework_dir}/${FRAMEWORK_NAME}"
    else
        rm -rf "${framework_dir}"
        mkdir -p "$(dirname "${framework_dir}")"
        cp -R "${produced_framework}" "${framework_dir}"
        # Drop any Xcode-generated resources we don't need in the shipped
        # framework (Info.plist stays; PkgInfo can go).
        rm -f "${framework_dir}/PkgInfo"
    fi

    # Public headers. Swift's C interop reads them through the module map, so
    # they must live under Headers/foundry_local_mobile/ to match the include
    # paths every binding uses.
    mkdir -p "${framework_dir}/Headers/foundry_local_mobile"
    cp -R "${REPO_ROOT}/core/include/foundry_local_mobile/." \
        "${framework_dir}/Headers/foundry_local_mobile/"

    mkdir -p "${framework_dir}/Modules"
    cat >"${framework_dir}/Modules/module.modulemap" <<MODMAP
framework module ${FRAMEWORK_NAME} {
    umbrella header "foundry_local_mobile/flm_api.h"
    header "foundry_local_mobile/flm_types.h"
    header "foundry_local_mobile/flm_export.h"
    header "foundry_local_mobile/flm_dart_bridge.h"
    export *
    module * { export * }
}
MODMAP

    # A minimum-viable Info.plist so xcodebuild treats this as a real framework.
    # CMake writes one when it drives the build; supply our own when we fell
    # back to wrapping a plain dylib.
    if [[ ! -f "${framework_dir}/Info.plist" ]]; then
        cat >"${framework_dir}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>${FRAMEWORK_NAME}</string>
    <key>CFBundleIdentifier</key><string>com.microsoft.ai.foundry.local.mobile</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${FRAMEWORK_NAME}</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>0.2.0</string>
</dict>
</plist>
PLIST
    fi

    printf '%s\n' "${framework_dir}"
}

# Harvest the OGA framework produced by the subdirectory build alongside a
# given FLM slice. The OGA CMake target produces either a .framework (when
# BUILD_APPLE_FRAMEWORK=ON and Xcode generator) or a plain dylib/static lib.
# We wrap it into a .framework suitable for xcframework assembly.
OGA_FRAMEWORK_NAME="onnxruntime-genai"

harvest_oga_framework() {
    local slice_id="$1"
    local build_dir="${OUTPUT_DIR}/cmake/${slice_id}"
    local install_dir="${OUTPUT_DIR}/install/${slice_id}"
    local oga_fw_dir="${install_dir}/${OGA_FRAMEWORK_NAME}.framework"

    # Look for a produced .framework first (Xcode + BUILD_APPLE_FRAMEWORK=ON).
    local produced_oga_fw
    produced_oga_fw="$(find "${build_dir}" -type d -name "${OGA_FRAMEWORK_NAME}.framework" -print -quit 2>/dev/null || true)"
    if [[ -n "${produced_oga_fw}" ]]; then
        rm -rf "${oga_fw_dir}"
        mkdir -p "$(dirname "${oga_fw_dir}")"
        cp -R "${produced_oga_fw}" "${oga_fw_dir}"
        rm -f "${oga_fw_dir}/PkgInfo"
    else
        # Fallback: locate a plain dylib or static lib and wrap it.
        local oga_lib
        oga_lib="$(find "${build_dir}" -type f \( -name "libonnxruntime-genai.dylib" -o -name "libonnxruntime-genai.a" \) -print -quit 2>/dev/null || true)"
        if [[ -z "${oga_lib}" ]]; then
            warn "no onnxruntime-genai library found for ${slice_id}; OGA xcframework will be incomplete"
            return 1
        fi
        rm -rf "${oga_fw_dir}"
        mkdir -p "${oga_fw_dir}/Headers"
        cp "${oga_lib}" "${oga_fw_dir}/${OGA_FRAMEWORK_NAME}"
    fi

    # Headers — ship the public OGA C header.
    local oga_src_dir="${REPO_ROOT}/third_party/onnxruntime-genai/src"
    mkdir -p "${oga_fw_dir}/Headers"
    if [[ -f "${oga_src_dir}/ort_genai_c.h" ]]; then
        cp "${oga_src_dir}/ort_genai_c.h" "${oga_fw_dir}/Headers/"
    fi
    if [[ -f "${oga_src_dir}/ort_genai.h" ]]; then
        cp "${oga_src_dir}/ort_genai.h" "${oga_fw_dir}/Headers/"
    fi

    # Module map
    mkdir -p "${oga_fw_dir}/Modules"
    cat >"${oga_fw_dir}/Modules/module.modulemap" <<MODMAP
framework module onnxruntime_genai {
    header "ort_genai_c.h"
    export *
}
MODMAP

    # Info.plist
    if [[ ! -f "${oga_fw_dir}/Info.plist" ]]; then
        cat >"${oga_fw_dir}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>${OGA_FRAMEWORK_NAME}</string>
    <key>CFBundleIdentifier</key><string>com.microsoft.onnxruntime-genai</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${OGA_FRAMEWORK_NAME}</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>0.5.0</string>
    <key>CFBundleVersion</key><string>0.5.0</string>
</dict>
</plist>
PLIST
    fi

    printf '%s\n' "${oga_fw_dir}"
}

log "building iOS device slice (arm64)"
IOS_DEVICE_FRAMEWORK="$(build_slice \
    "ios-arm64" \
    "${IPHONEOS_SDK_PATH}" \
    "arm64" \
    "CMAKE_OSX_DEPLOYMENT_TARGET" \
    "${IOS_DEPLOYMENT_TARGET}")"
IOS_DEVICE_OGA_FRAMEWORK="$(harvest_oga_framework "ios-arm64")"

# Two simulator arches → two builds, then lipo. -create-xcframework will refuse
# ("Both … represent two equivalent library definitions") if we hand it two
# separate frameworks tagged ios-simulator, so we have to fuse them ourselves.
log "building iOS simulator slice (arm64)"
IOS_SIM_ARM64_FRAMEWORK="$(build_slice \
    "ios-sim-arm64" \
    "${IPHONESIMULATOR_SDK_PATH}" \
    "arm64" \
    "CMAKE_OSX_DEPLOYMENT_TARGET" \
    "${IOS_DEPLOYMENT_TARGET}")"
IOS_SIM_ARM64_OGA_FRAMEWORK="$(harvest_oga_framework "ios-sim-arm64")"

log "building iOS simulator slice (x86_64)"
IOS_SIM_X86_FRAMEWORK="$(build_slice \
    "ios-sim-x86_64" \
    "${IPHONESIMULATOR_SDK_PATH}" \
    "x86_64" \
    "CMAKE_OSX_DEPLOYMENT_TARGET" \
    "${IOS_DEPLOYMENT_TARGET}")"
IOS_SIM_X86_OGA_FRAMEWORK="$(harvest_oga_framework "ios-sim-x86_64")"

# --- lipo FLM simulator slices ---
IOS_SIM_FAT_DIR="${OUTPUT_DIR}/install/ios-sim-fat"
IOS_SIM_FAT_FRAMEWORK="${IOS_SIM_FAT_DIR}/${FRAMEWORK_NAME}.framework"
rm -rf "${IOS_SIM_FAT_DIR}"
mkdir -p "$(dirname "${IOS_SIM_FAT_FRAMEWORK}")"
cp -R "${IOS_SIM_ARM64_FRAMEWORK}" "${IOS_SIM_FAT_FRAMEWORK}"
log "lipo-ing simulator arm64 + x86_64 into one binary"
lipo -create \
    "${IOS_SIM_ARM64_FRAMEWORK}/${FRAMEWORK_NAME}" \
    "${IOS_SIM_X86_FRAMEWORK}/${FRAMEWORK_NAME}" \
    -output "${IOS_SIM_FAT_FRAMEWORK}/${FRAMEWORK_NAME}"

# --- lipo OGA simulator slices ---
IOS_SIM_FAT_OGA_FRAMEWORK="${IOS_SIM_FAT_DIR}/${OGA_FRAMEWORK_NAME}.framework"
if [[ -n "${IOS_SIM_ARM64_OGA_FRAMEWORK}" && -n "${IOS_SIM_X86_OGA_FRAMEWORK}" ]]; then
    cp -R "${IOS_SIM_ARM64_OGA_FRAMEWORK}" "${IOS_SIM_FAT_OGA_FRAMEWORK}"
    log "lipo-ing OGA simulator arm64 + x86_64 into one binary"
    lipo -create \
        "${IOS_SIM_ARM64_OGA_FRAMEWORK}/${OGA_FRAMEWORK_NAME}" \
        "${IOS_SIM_X86_OGA_FRAMEWORK}/${OGA_FRAMEWORK_NAME}" \
        -output "${IOS_SIM_FAT_OGA_FRAMEWORK}/${OGA_FRAMEWORK_NAME}"
fi

XCFRAMEWORK_ARGS=(
    -framework "${IOS_DEVICE_FRAMEWORK}"
    -framework "${IOS_SIM_FAT_FRAMEWORK}"
)

OGA_XCFRAMEWORK_ARGS=(
    -framework "${IOS_DEVICE_OGA_FRAMEWORK}"
    -framework "${IOS_SIM_FAT_OGA_FRAMEWORK}"
)

if [[ ${INCLUDE_MACOS} -eq 1 ]]; then
    log "building macOS slice (arm64 + x86_64)"
    MACOS_FRAMEWORK="$(build_slice \
        "macos" \
        "${MACOSX_SDK_PATH}" \
        "arm64;x86_64" \
        "CMAKE_OSX_DEPLOYMENT_TARGET" \
        "${MACOS_DEPLOYMENT_TARGET}")"
    MACOS_OGA_FRAMEWORK="$(harvest_oga_framework "macos")"
    XCFRAMEWORK_ARGS+=(-framework "${MACOS_FRAMEWORK}")
    if [[ -n "${MACOS_OGA_FRAMEWORK}" ]]; then
        OGA_XCFRAMEWORK_ARGS+=(-framework "${MACOS_OGA_FRAMEWORK}")
    fi
fi

XCFRAMEWORK_OUT="${OUTPUT_DIR}/${FRAMEWORK_NAME}.xcframework"
rm -rf "${XCFRAMEWORK_OUT}"

log "packaging ${FRAMEWORK_NAME}.xcframework"
xcodebuild -create-xcframework \
    "${XCFRAMEWORK_ARGS[@]}" \
    -output "${XCFRAMEWORK_OUT}"

OGA_XCFRAMEWORK_OUT="${OUTPUT_DIR}/${OGA_FRAMEWORK_NAME}.xcframework"
rm -rf "${OGA_XCFRAMEWORK_OUT}"

log "packaging ${OGA_FRAMEWORK_NAME}.xcframework"
xcodebuild -create-xcframework \
    "${OGA_XCFRAMEWORK_ARGS[@]}" \
    -output "${OGA_XCFRAMEWORK_OUT}"

log "done. XCFrameworks at:"
log "  ${XCFRAMEWORK_OUT}"
log "  ${OGA_XCFRAMEWORK_OUT}"
