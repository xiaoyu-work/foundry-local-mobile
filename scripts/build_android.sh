#!/usr/bin/env bash
# Cross-compile the mobile core for one or all Android ABIs and lay it out as
#
#   <output>/jniLibs/
#     arm64-v8a/libfoundry_local_mobile.so
#     armeabi-v7a/libfoundry_local_mobile.so
#     x86_64/libfoundry_local_mobile.so
#
# which is the on-disk shape the Android binding's AAR consumes directly. The
# NDK's Android CMake toolchain does the heavy lifting; this script is just the
# thin wrapper that keeps ABI choice, sysroot level, output layout and stripping
# consistent across developer machines and CI.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEFAULT_ABIS=(arm64-v8a armeabi-v7a x86_64)
# API 26 == Android 8.0. Matches the min supported OS documented in the SDK.
DEFAULT_PLATFORM=26
DEFAULT_STL=c++_shared

BUILD_TYPE="RelWithDebInfo"
OUTPUT_DIR="${REPO_ROOT}/build/android"
ABIS=()
PLATFORM="${DEFAULT_PLATFORM}"
STL="${DEFAULT_STL}"
STRIP_RELEASE=1
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
CLEAN=0
VERBOSE=0

usage() {
    cat <<EOF
${SCRIPT_NAME} — cross-compile the core for Android

Usage:
  ${SCRIPT_NAME} [options]

Options:
  --abi <name>          Target ABI. May be repeated (e.g. --abi arm64-v8a
                        --abi x86_64). Default: ${DEFAULT_ABIS[*]}.
  --build-type <type>   CMake build type. Default: ${BUILD_TYPE}.
  --output <path>       Output root. Default: <repo>/build/android.
                        The final layout is <output>/jniLibs/<abi>/lib*.so.
  --platform <level>    ANDROID_PLATFORM level. Default: ${DEFAULT_PLATFORM}.
  --stl <name>          ANDROID_STL (c++_shared | c++_static). Default: ${DEFAULT_STL}.
  --no-strip            Skip stripping release-mode binaries.
  --jobs <n>            Parallel build jobs. Default: detected CPU count.
  --clean               Remove <output> before building.
  --verbose             Show every command.
  -h, --help            This help.

Environment:
  ANDROID_NDK_HOME      Required. Path to the NDK. \$ANDROID_NDK_ROOT is used
                        as a fallback for compatibility with older tooling.

Exit status:
  0  every requested ABI built successfully
  1  configuration or build failed
  2  a prerequisite is missing
EOF
}

log()  { printf '[android] %s\n' "$*"; }
warn() { printf '[android] warn: %s\n' "$*" >&2; }
die()  { printf '[android] error: %s\n' "$1" >&2; exit "${2:-1}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --abi)          ABIS+=("$2"); shift 2 ;;
        --abi=*)        ABIS+=("${1#*=}"); shift ;;
        --build-type)   BUILD_TYPE="$2"; shift 2 ;;
        --build-type=*) BUILD_TYPE="${1#*=}"; shift ;;
        --output)       OUTPUT_DIR="$2"; shift 2 ;;
        --output=*)     OUTPUT_DIR="${1#*=}"; shift ;;
        --platform)     PLATFORM="$2"; shift 2 ;;
        --platform=*)   PLATFORM="${1#*=}"; shift ;;
        --stl)          STL="$2"; shift 2 ;;
        --stl=*)        STL="${1#*=}"; shift ;;
        --no-strip)     STRIP_RELEASE=0; shift ;;
        --jobs)         JOBS="$2"; shift 2 ;;
        --jobs=*)       JOBS="${1#*=}"; shift ;;
        --clean)        CLEAN=1; shift ;;
        --verbose)      VERBOSE=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              die "unknown option: $1 (try --help)" ;;
    esac
done

[[ ${VERBOSE} -eq 1 ]] && set -x

if [[ ${#ABIS[@]} -eq 0 ]]; then
    ABIS=("${DEFAULT_ABIS[@]}")
fi

# Fall back to ANDROID_NDK_ROOT so this works with legacy Gradle configurations
# and with sdkmanager installations that only set the older variable.
: "${ANDROID_NDK_HOME:=${ANDROID_NDK_ROOT:-}}"
if [[ -z "${ANDROID_NDK_HOME}" ]]; then
    die "ANDROID_NDK_HOME is not set. Install the NDK and export ANDROID_NDK_HOME=/path/to/ndk (or ANDROID_NDK_ROOT)." 2
fi

TOOLCHAIN="${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake"
if [[ ! -f "${TOOLCHAIN}" ]]; then
    die "NDK toolchain file not found at ${TOOLCHAIN}. Check ANDROID_NDK_HOME=${ANDROID_NDK_HOME}." 2
fi

command -v cmake >/dev/null 2>&1 || die "cmake is required but not on PATH" 2

if [[ ${CLEAN} -eq 1 && -d "${OUTPUT_DIR}" ]]; then
    log "removing ${OUTPUT_DIR}"
    rm -rf "${OUTPUT_DIR}"
fi

JNI_LIBS_DIR="${OUTPUT_DIR}/jniLibs"
mkdir -p "${JNI_LIBS_DIR}"

# The NDK bundles llvm-strip under toolchains/llvm/prebuilt/<host>/bin. Detect
# it once so every ABI reuses the same binary rather than re-globbing.
STRIP_BIN=""
if [[ ${STRIP_RELEASE} -eq 1 ]]; then
    for candidate in "${ANDROID_NDK_HOME}"/toolchains/llvm/prebuilt/*/bin/llvm-strip; do
        if [[ -x "${candidate}" ]]; then
            STRIP_BIN="${candidate}"
            break
        fi
    done
    if [[ -z "${STRIP_BIN}" ]]; then
        warn "llvm-strip not found under ${ANDROID_NDK_HOME}; skipping strip"
    fi
fi

is_release_type() {
    case "$1" in
        Release|MinSizeRel|RelWithDebInfo) return 0 ;;
        *) return 1 ;;
    esac
}

# Map an Android ABI to its NDK sysroot triple. This is where the STL and the
# various support libraries live inside the NDK.
ndk_triple_for_abi() {
    case "$1" in
        arm64-v8a)   echo aarch64-linux-android ;;
        armeabi-v7a) echo arm-linux-androideabi ;;
        x86)         echo i686-linux-android ;;
        x86_64)      echo x86_64-linux-android ;;
        *)           echo "" ;;
    esac
}

# Locate an ABI-specific NDK library, printing its absolute path on stdout or
# an empty string if it is not present. Silent — the caller decides how loudly
# a missing file is a problem.
ndk_lib_for_abi() {
    local abi="$1" name="$2"
    local triple
    triple="$(ndk_triple_for_abi "${abi}")"
    [[ -z "${triple}" ]] && return 0
    local candidate
    for candidate in \
            "${ANDROID_NDK_HOME}"/toolchains/llvm/prebuilt/*/sysroot/usr/lib/"${triple}"/"${name}"; do
        if [[ -f "${candidate}" ]]; then
            echo "${candidate}"
            return 0
        fi
    done
}

# Assert the loadable segments of a 64-bit AAR-bound library are 16 KB aligned.
# Android 15+ on 64-bit devices refuses to map a shared object with 4 KB LOAD
# segments, so this catches a silent regression of `-Wl,-z,max-page-size=16384`
# — a linker flag that the linker itself will never complain about if it is
# dropped or misspelled. armeabi-v7a is 32-bit and exempt.
assert_16k_aligned_load_segments() {
    local abi="$1" so="$2"
    case "${abi}" in
        arm64-v8a|x86_64) ;;
        *) return 0 ;;
    esac
    local readelf=""
    for candidate in "${ANDROID_NDK_HOME}"/toolchains/llvm/prebuilt/*/bin/llvm-readelf; do
        if [[ -x "${candidate}" ]]; then readelf="${candidate}"; break; fi
    done
    if [[ -z "${readelf}" ]] && command -v llvm-readelf >/dev/null 2>&1; then
        readelf=llvm-readelf
    elif [[ -z "${readelf}" ]] && command -v readelf >/dev/null 2>&1; then
        readelf=readelf
    fi
    if [[ -z "${readelf}" ]]; then
        warn "no readelf on PATH; skipping 16 KB alignment check on ${so}"
        return 0
    fi
    local aligns
    aligns=$("${readelf}" -lW "${so}" | awk '$1 == "LOAD" { print $NF }')
    [[ -z "${aligns}" ]] && die "no LOAD segments found in ${so}; the artifact is malformed"
    local align
    for align in ${aligns}; do
        if [[ "${align}" != "0x4000" ]]; then
            die "${so} has LOAD segment with Align=${align}, expected 0x4000 (16 KB). Android 15+ 64-bit devices will refuse to load it. Check -Wl,-z,max-page-size=16384."
        fi
    done
}

build_one_abi() {
    local abi="$1"
    local build_dir="${OUTPUT_DIR}/cmake/${abi}"
    log "configuring ${abi} (platform=${PLATFORM}, build_type=${BUILD_TYPE}, stl=${STL})"

    local -a cmake_args=(
        -S "${REPO_ROOT}/core"
        -B "${build_dir}"
        -DCMAKE_BUILD_TYPE="${BUILD_TYPE}"
        -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}"
        -DANDROID_ABI="${abi}"
        -DANDROID_PLATFORM="android-${PLATFORM}"
        -DANDROID_STL="${STL}"
        -DFLM_BUILD_SHARED=ON
    )
    if command -v ninja >/dev/null 2>&1; then
        cmake_args+=(-G Ninja)
    fi
    cmake "${cmake_args[@]}"
    cmake --build "${build_dir}" --config "${BUILD_TYPE}" --parallel "${JOBS}"

    local lib_src="${build_dir}/libfoundry_local_mobile.so"
    if [[ ! -f "${lib_src}" ]]; then
        die "expected ${lib_src} after build for ${abi}, but it was not produced"
    fi

    local lib_dst_dir="${JNI_LIBS_DIR}/${abi}"
    mkdir -p "${lib_dst_dir}"
    cp "${lib_src}" "${lib_dst_dir}/libfoundry_local_mobile.so"

    # RelWithDebInfo keeps a heavy .debug_info section that Gradle ships to
    # devices, doubling the AAR size and revealing symbol names. Strip after
    # copying so the original stays in the CMake build tree for local
    # debugging.
    if [[ -n "${STRIP_BIN}" ]] && is_release_type "${BUILD_TYPE}"; then
        "${STRIP_BIN}" --strip-unneeded "${lib_dst_dir}/libfoundry_local_mobile.so"
    fi

    # ---------- ONNX Runtime GenAI + ONNX Runtime shared libraries ----------
    # The core dlopens libonnxruntime-genai.so at runtime, which in turn
    # dlopens libonnxruntime.so. Both must ship in the same jniLibs/<abi>/
    # directory so Android's class loader can resolve them. The nested OGA
    # CMake build produces libonnxruntime-genai.so under the build tree and
    # downloads libonnxruntime.so into ORT_LIB_DIR.

    # 1) libonnxruntime-genai.so — produced by the OGA subdirectory build.
    local oga_so=""
    oga_so="$(find "${build_dir}" -name 'libonnxruntime-genai.so' -type f -print -quit 2>/dev/null || true)"
    if [[ -z "${oga_so}" ]]; then
        die "libonnxruntime-genai.so not found under ${build_dir}. The OGA subdirectory build may have failed."
    fi
    cp "${oga_so}" "${lib_dst_dir}/libonnxruntime-genai.so"
    if [[ -n "${STRIP_BIN}" ]] && is_release_type "${BUILD_TYPE}"; then
        "${STRIP_BIN}" --strip-unneeded "${lib_dst_dir}/libonnxruntime-genai.so"
    fi
    log "wrote ${lib_dst_dir}/libonnxruntime-genai.so"

    # 2) libonnxruntime.so — the OGA build downloads ONNX Runtime into a
    #    FetchContent or ORT_HOME directory. Walk up from the OGA .so to
    #    locate it deterministically.
    local ort_so=""
    ort_so="$(find "${build_dir}" -path "*/jni/${abi}/libonnxruntime.so" -type f -print -quit 2>/dev/null || true)"
    if [[ -z "${ort_so}" ]]; then
        die "libonnxruntime.so not found under ${build_dir}. ONNX Runtime may not have been fetched by OGA's cmake/ortlib.cmake."
    fi
    cp "${ort_so}" "${lib_dst_dir}/libonnxruntime.so"
    if [[ -n "${STRIP_BIN}" ]] && is_release_type "${BUILD_TYPE}"; then
        "${STRIP_BIN}" --strip-unneeded "${lib_dst_dir}/libonnxruntime.so"
    fi
    log "wrote ${lib_dst_dir}/libonnxruntime.so"

    # 3) Optional provider libraries (e.g. libonnxruntime_providers_*.so).
    #    Ship them when present so acceleration paths that rely on them work.
    while IFS= read -r -d '' prov_so; do
        local prov_name
        prov_name="$(basename "${prov_so}")"
        cp "${prov_so}" "${lib_dst_dir}/${prov_name}"
        if [[ -n "${STRIP_BIN}" ]] && is_release_type "${BUILD_TYPE}"; then
            "${STRIP_BIN}" --strip-unneeded "${lib_dst_dir}/${prov_name}"
        fi
        log "wrote ${lib_dst_dir}/${prov_name} (optional provider)"
    done < <(find "${build_dir}" -path "*/jni/${abi}/libonnxruntime_providers_*.so" -type f -print0 2>/dev/null || true)

    # Ship the STL alongside the library. libfoundry_local_mobile.so links
    # dynamically against libc++_shared.so (see readelf -d), so any consumer
    # AAR must include it in the same jniLibs/<abi>/ directory or the app
    # crashes with `dlopen failed: cannot locate libc++_shared.so`. The
    # Gradle native integration copies it automatically when it drives the
    # build; this script does not go through Gradle, so it does the copy
    # itself and keeps the output tree self-contained.
    if [[ "${STL}" == "c++_shared" ]]; then
        local stl_src
        stl_src="$(ndk_lib_for_abi "${abi}" libc++_shared.so)"
        if [[ -n "${stl_src}" ]]; then
            cp "${stl_src}" "${lib_dst_dir}/libc++_shared.so"
            if [[ -n "${STRIP_BIN}" ]] && is_release_type "${BUILD_TYPE}"; then
                "${STRIP_BIN}" --strip-unneeded "${lib_dst_dir}/libc++_shared.so"
            fi
            log "wrote ${lib_dst_dir}/libc++_shared.so"
        else
            warn "libc++_shared.so not found in the NDK for ${abi}; consumers must supply it"
        fi
    fi

    # 16-KB alignment assertions for all 64-bit native libraries.
    assert_16k_aligned_load_segments "${abi}" "${lib_dst_dir}/libfoundry_local_mobile.so"
    assert_16k_aligned_load_segments "${abi}" "${lib_dst_dir}/libonnxruntime-genai.so"
    assert_16k_aligned_load_segments "${abi}" "${lib_dst_dir}/libonnxruntime.so"

    log "wrote ${lib_dst_dir}/libfoundry_local_mobile.so"
}

for abi in "${ABIS[@]}"; do
    case "${abi}" in
        arm64-v8a|armeabi-v7a|x86|x86_64) ;;
        *) die "unsupported ABI '${abi}'. Expected one of: arm64-v8a armeabi-v7a x86 x86_64" ;;
    esac
    build_one_abi "${abi}"
done

log "done. Artifacts under ${JNI_LIBS_DIR}"
