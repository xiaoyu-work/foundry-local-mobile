#!/usr/bin/env bash
# Fetch the Foundry Local SDK headers (and any prebuilt runtime libraries) that
# core/CMakeLists.txt binds against. The core dlopens libfoundry_local at run
# time on device, so headers are the compile-time hard dependency and libraries
# are optional here.
#
# Layout produced (idempotent):
#   third_party/foundry-local/
#     .stamp               # ref + SHA-256 of the fetched headers
#     LICENSE              # upstream license
#     include/foundry_local/foundry_local_c.h
#     include/foundry_local/foundry_local_cpp.h
#     include/foundry_local/foundry_local_cpp.inline.h
#     lib/<platform>/…     # if --with-libs and a matching prebuilt is found
#
# The path matches the second candidate probed in core/CMakeLists.txt, so a
# plain `cmake -S core` finds the headers without any -D flag.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Default upstream. Both the ref and the URL are overridable so an internal
# mirror or a fork can drive this script without editing it.
UPSTREAM_URL="${FLM_FOUNDRY_LOCAL_URL:-https://github.com/microsoft/Foundry-Local.git}"
DEFAULT_REF="cli-preview-0.10.2"
REF="${FLM_FOUNDRY_LOCAL_REF:-${DEFAULT_REF}}"

DEST_DIR="${REPO_ROOT}/third_party/foundry-local"
LOCAL_SDK_ROOT=""
WITH_LIBS=0
FORCE=0
VERBOSE=0
VERIFY_ONLY=0

usage() {
    cat <<EOF
${SCRIPT_NAME} — stage the Foundry Local C SDK for core/CMakeLists.txt

Usage:
  ${SCRIPT_NAME} [options]

Options:
  --ref <git-ref>       Tag, branch or commit to fetch (default: ${DEFAULT_REF}).
                        Overridable via FLM_FOUNDRY_LOCAL_REF.
  --url <git-url>       Upstream repository (default: ${UPSTREAM_URL}).
                        Overridable via FLM_FOUNDRY_LOCAL_URL.
  --local <path>        Use an already checked-out Foundry-Local repo instead of
                        cloning. The path must contain sdk_v2/cpp/include.
                        Overridable via FLM_FOUNDRY_LOCAL_LOCAL.
  --dest <path>         Where to stage headers (default: ${DEST_DIR}).
  --with-libs           Also copy prebuilt runtime libraries if the source
                        exposes them under sdk_v2/cpp/lib. Missing lib
                        directories are not an error — the core dlopens at run
                        time — but this lets a developer link locally.
  --force               Re-fetch even if the destination is already valid.
  --verify              Only verify the current staged headers; do not fetch.
  --verbose             Show every command as it runs.
  -h, --help            This help.

Environment:
  FLM_FOUNDRY_LOCAL_REF     Same as --ref.
  FLM_FOUNDRY_LOCAL_URL     Same as --url.
  FLM_FOUNDRY_LOCAL_LOCAL   Same as --local.

Exit status:
  0  headers ready at \$DEST_DIR/include/foundry_local/foundry_local_c.h
  1  a prerequisite is missing or a fetch failed
  2  verification failed

EOF
}

log()  { printf '[fetch] %s\n' "$*"; }
warn() { printf '[fetch] warn: %s\n' "$*" >&2; }
die()  { printf '[fetch] error: %s\n' "$*" >&2; exit 1; }

require() {
    command -v "$1" >/dev/null 2>&1 \
        || die "'$1' is required but not on PATH. Install it and re-run."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ref)         REF="$2"; shift 2 ;;
        --ref=*)       REF="${1#*=}"; shift ;;
        --url)         UPSTREAM_URL="$2"; shift 2 ;;
        --url=*)       UPSTREAM_URL="${1#*=}"; shift ;;
        --local)       LOCAL_SDK_ROOT="$2"; shift 2 ;;
        --local=*)     LOCAL_SDK_ROOT="${1#*=}"; shift ;;
        --dest)        DEST_DIR="$2"; shift 2 ;;
        --dest=*)      DEST_DIR="${1#*=}"; shift ;;
        --with-libs)   WITH_LIBS=1; shift ;;
        --force)       FORCE=1; shift ;;
        --verify)      VERIFY_ONLY=1; shift ;;
        --verbose)     VERBOSE=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "unknown option: $1 (try --help)" ;;
    esac
done

if [[ -z "${LOCAL_SDK_ROOT}" && -n "${FLM_FOUNDRY_LOCAL_LOCAL:-}" ]]; then
    LOCAL_SDK_ROOT="${FLM_FOUNDRY_LOCAL_LOCAL}"
fi

[[ ${VERBOSE} -eq 1 ]] && set -x

HEADER_REL="include/foundry_local/foundry_local_c.h"
STAMP_FILE="${DEST_DIR}/.stamp"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        die "neither sha256sum nor shasum is available"
    fi
}

verify_dest() {
    local header="${DEST_DIR}/${HEADER_REL}"
    if [[ ! -f "${header}" ]]; then
        return 1
    fi
    # Header must expose the ABI-version macro the core binds against, or the
    # file we fetched is not what we think it is.
    if ! grep -q "FOUNDRY_LOCAL_API_VERSION" "${header}"; then
        warn "${header} does not define FOUNDRY_LOCAL_API_VERSION"
        return 2
    fi
    if [[ -f "${STAMP_FILE}" ]]; then
        # Compare the stored hash against the on-disk header so a partial or
        # tampered install fails verification instead of silently succeeding.
        local recorded actual
        recorded="$(awk -F= '$1=="sha256"{print $2}' "${STAMP_FILE}")"
        actual="$(sha256_of "${header}")"
        if [[ -n "${recorded}" && "${recorded}" != "${actual}" ]]; then
            warn "recorded SHA-256 does not match on-disk header (${recorded} != ${actual})"
            return 2
        fi
    fi
    return 0
}

write_stamp() {
    local source_desc="$1"
    local header="${DEST_DIR}/${HEADER_REL}"
    local hash
    hash="$(sha256_of "${header}")"
    cat >"${STAMP_FILE}" <<EOF
# Written by ${SCRIPT_NAME}; do not edit.
source=${source_desc}
sha256=${hash}
fetched_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

stage_from_directory() {
    local src="$1"
    local include_src="${src}/sdk_v2/cpp/include"
    if [[ ! -f "${include_src}/foundry_local/foundry_local_c.h" ]]; then
        die "no Foundry Local SDK headers at ${include_src}. Expected sdk_v2/cpp/include/foundry_local/foundry_local_c.h."
    fi

    mkdir -p "${DEST_DIR}/include"
    # `cp -R foo/. bar/` copies contents rather than the directory itself, which
    # is what we want when re-running: the destination stays clean.
    rm -rf "${DEST_DIR}/include/foundry_local"
    cp -R "${include_src}/foundry_local" "${DEST_DIR}/include/"

    if [[ -f "${src}/LICENSE" ]]; then
        cp "${src}/LICENSE" "${DEST_DIR}/LICENSE"
    fi

    if [[ ${WITH_LIBS} -eq 1 ]]; then
        local lib_src="${src}/sdk_v2/cpp/lib"
        if [[ -d "${lib_src}" ]]; then
            mkdir -p "${DEST_DIR}/lib"
            cp -R "${lib_src}/." "${DEST_DIR}/lib/"
            log "copied prebuilt libraries from ${lib_src}"
        else
            warn "--with-libs was passed but ${lib_src} does not exist; skipping"
        fi
    fi
}

fetch_from_git() {
    require git
    local work_dir="${DEST_DIR}/.git-checkout"
    rm -rf "${work_dir}"
    mkdir -p "${work_dir}"

    log "cloning ${UPSTREAM_URL} at ${REF}"
    # A shallow single-branch clone is enough because we only stage headers;
    # falling back to a full clone lets a commit SHA (which cannot be fetched
    # shallowly by default) still work.
    if ! git clone --depth 1 --branch "${REF}" --single-branch \
            "${UPSTREAM_URL}" "${work_dir}" 2>/dev/null; then
        log "shallow clone of ${REF} failed; retrying with a full clone"
        rm -rf "${work_dir}"
        git clone "${UPSTREAM_URL}" "${work_dir}"
        git -C "${work_dir}" checkout "${REF}"
    fi

    stage_from_directory "${work_dir}"
    rm -rf "${work_dir}"
}

if [[ ${VERIFY_ONLY} -eq 1 ]]; then
    if verify_dest; then
        log "verified: ${DEST_DIR}/${HEADER_REL}"
        exit 0
    fi
    die "verification failed for ${DEST_DIR}"
fi

if [[ ${FORCE} -ne 1 ]] && verify_dest; then
    log "already staged at ${DEST_DIR}; use --force to re-fetch"
    exit 0
fi

mkdir -p "${DEST_DIR}"

source_desc=""
if [[ -n "${LOCAL_SDK_ROOT}" ]]; then
    LOCAL_SDK_ROOT="$(cd "${LOCAL_SDK_ROOT}" && pwd)" \
        || die "--local path does not exist: ${LOCAL_SDK_ROOT}"
    log "staging headers from local checkout: ${LOCAL_SDK_ROOT}"
    stage_from_directory "${LOCAL_SDK_ROOT}"
    source_desc="local:${LOCAL_SDK_ROOT}"
else
    fetch_from_git
    source_desc="git:${UPSTREAM_URL}@${REF}"
fi

if ! verify_dest; then
    die "post-fetch verification failed. The upstream layout may have changed; \
inspect ${DEST_DIR}/${HEADER_REL} and re-run."
fi

write_stamp "${source_desc}"
log "staged Foundry Local headers at ${DEST_DIR}/${HEADER_REL}"
