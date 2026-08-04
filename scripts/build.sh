#!/usr/bin/env bash
# Top-level entry point for the mobile core cross-builds.
#
# Kept thin on purpose: this script sequences the per-target scripts and does no
# building of its own. Passing platform-specific flags is done via the target
# script directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
    cat <<EOF
build.sh — driver for the mobile core cross-builds

Usage:
  build.sh <command> [target] [-- forwarded-args…]

Commands:
  fetch                 Stage the Foundry Local SDK headers (scripts/fetch_foundry_local.sh).
  android [target]      Build the core for Android ABIs (scripts/build_android.sh).
                        Default target is 'all' (arm64-v8a + armeabi-v7a + x86_64).
                        A specific ABI (arm64-v8a, x86_64, ...) may be given
                        instead and is forwarded as --abi.
  android-binding       Assemble bindings/android as an AAR via Gradle.
                        Needs a JDK 17 and either \$ANDROID_HOME or
                        \$ANDROID_SDK_ROOT pointing at an SDK with
                        platforms/android-35, build-tools/35.0.0,
                        ndk/27.0.12077973 and cmake/3.22.1 installed.
                        Forwarded arguments become extra ./gradlew arguments,
                        e.g. \`-- --stacktrace\` or \`-- assembleDebug\`.
  apple                 Build the core as an Apple XCFramework (scripts/build_apple.sh).
                        Requires a macOS host.
  linux                 Configure and build the core natively via CMake — used
                        by CI and by developers to sanity-check changes without
                        an emulator or a device.
  all                   fetch + android all + apple (apple is skipped on non-macOS).
  clean                 Remove build/ and third_party/foundry-local/.

Any arguments after \`--\` are forwarded to the underlying script, e.g.

  build.sh android arm64-v8a -- --build-type Debug --platform 28
  build.sh apple -- --macos --clean

Environment mirrors the individual scripts; see fetch_foundry_local.sh,
build_android.sh, build_apple.sh.

EOF
}

if [[ $# -eq 0 ]]; then
    usage
    exit 0
fi

COMMAND="$1"; shift
TARGET=""

# Peel off a positional target argument for the commands that accept one (only
# `android` does today) before the `--` sentinel.
case "${COMMAND}" in
    android)
        if [[ $# -gt 0 && "$1" != --* && "$1" != "--" ]]; then
            TARGET="$1"; shift
        fi
        ;;
esac

FORWARDED=()
if [[ $# -gt 0 && "$1" == "--" ]]; then
    shift
    FORWARDED=("$@")
elif [[ $# -gt 0 ]]; then
    FORWARDED=("$@")
fi

run_fetch() {
    "${SCRIPT_DIR}/fetch_foundry_local.sh" "${FORWARDED[@]}"
}

run_android() {
    local -a args=()
    if [[ -n "${TARGET}" && "${TARGET}" != "all" ]]; then
        args+=(--abi "${TARGET}")
    fi
    args+=("${FORWARDED[@]}")
    "${SCRIPT_DIR}/build_android.sh" "${args[@]}"
}

run_android_binding() {
    local module_dir="${REPO_ROOT}/bindings/android"
    if [[ ! -x "${module_dir}/gradlew" ]]; then
        printf '[build] error: %s/gradlew missing or not executable\n' \
            "${module_dir}" >&2
        exit 1
    fi
    if [[ -z "${ANDROID_HOME:-}" && -z "${ANDROID_SDK_ROOT:-}" ]]; then
        printf '[build] error: set ANDROID_HOME (or ANDROID_SDK_ROOT) to an SDK '\
'containing platforms/android-35, build-tools/35.0.0, ndk/27.0.12077973 and '\
'cmake/3.22.1. See docs/building.md.\n' >&2
        exit 1
    fi
    local -a gradle_args=(--no-daemon --console=plain)
    if [[ ${#FORWARDED[@]} -gt 0 ]]; then
        gradle_args+=("${FORWARDED[@]}")
    else
        gradle_args+=(assembleRelease)
    fi
    (cd "${module_dir}" && ./gradlew "${gradle_args[@]}")
}

run_apple() {
    "${SCRIPT_DIR}/build_apple.sh" "${FORWARDED[@]}"
}

run_linux() {
    # This target has no cross-compilation step and needs no separate script;
    # the small amount of CMake plumbing lives here.
    local build_dir="${REPO_ROOT}/build/linux"
    local -a cmake_args=(
        -S "${REPO_ROOT}/core"
        -B "${build_dir}"
        -DCMAKE_BUILD_TYPE=RelWithDebInfo
        -DFLM_BUILD_SHARED=ON
    )
    if command -v ninja >/dev/null 2>&1; then
        cmake_args+=(-G Ninja)
    fi
    cmake "${cmake_args[@]}" "${FORWARDED[@]}"
    cmake --build "${build_dir}" --parallel
}

run_clean() {
    rm -rf "${REPO_ROOT}/build" "${REPO_ROOT}/third_party/foundry-local"
}

case "${COMMAND}" in
    fetch)           run_fetch ;;
    android)         run_android ;;
    android-binding) run_android_binding ;;
    apple)           run_apple ;;
    linux)           run_linux ;;
    clean)           run_clean ;;
    all)
        run_fetch
        run_android
        if [[ "$(uname -s)" == "Darwin" ]]; then
            run_apple
        else
            printf '[build] skipping apple: not running on macOS\n' >&2
        fi
        ;;
    -h|--help|help) usage ;;
    *) printf '[build] error: unknown command %q. Try --help.\n' "${COMMAND}" >&2; exit 1 ;;
esac
