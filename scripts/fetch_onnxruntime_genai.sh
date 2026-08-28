#!/usr/bin/env bash
# Fetch (or stage from a local checkout) the ONNX Runtime GenAI source tree that
# core/CMakeLists.txt builds or links against.
#
# Layout produced (idempotent):
#   third_party/onnxruntime-genai/
#     .stamp                 # ref + SHA-256 of a sentinel file
#     LICENSE                # upstream license
#     CMakeLists.txt         # top-level build entry (add_subdirectory target)
#     src/ort_genai_c.h      # public C header the core compiles against
#     cmake/…, build.py, …   # full source tree needed for a subdirectory build
#
# When an installed package is available the script is optional — the core's
# CMake can find onnxruntime-genai via find_package(onnxruntime-genai CONFIG)
# and onnxruntime-genai_DIR.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---- defaults ---------------------------------------------------------------
UPSTREAM_URL="${OGA_URL:-https://github.com/microsoft/onnxruntime-genai.git}"
PINNED_REF="9d336e4db4e49eeceda909517b882c0d73cc6c86"
REF="${OGA_REF:-${PINNED_REF}}"

DEST_DIR="${REPO_ROOT}/third_party/onnxruntime-genai"
LOCAL_SRC=""
FORCE=0
VERBOSE=0
VERIFY_ONLY=0

# ---- usage -------------------------------------------------------------------
usage() {
    cat <<EOF
${SCRIPT_NAME} — stage ONNX Runtime GenAI sources for core/CMakeLists.txt

Usage:
  ${SCRIPT_NAME} [options]

Options:
  --ref <git-ref>       Commit, tag or branch to fetch
                        (default: ${PINNED_REF}).
                        Overridable via OGA_REF.
  --url <git-url>       Upstream repository
                        (default: ${UPSTREAM_URL}).
                        Overridable via OGA_URL.
  --local <path>        Use an already checked-out onnxruntime-genai repo
                        instead of cloning. The path must contain
                        src/ort_genai_c.h.
  --dest <path>         Where to stage the checkout
                        (default: ${DEST_DIR}).
  --force               Re-fetch even if the destination is already valid.
  --verify              Only verify the current staging; do not fetch.
  --verbose             Show every command as it runs.
  -h, --help            This help.

Environment:
  OGA_REF               Same as --ref.
  OGA_URL               Same as --url.

Exit status:
  0  sources ready at \$DEST_DIR/src/ort_genai_c.h
  1  a prerequisite is missing or a fetch failed
  2  verification failed

EOF
}

log()  { printf '[fetch-oga] %s\n' "$*"; }
warn() { printf '[fetch-oga] warn: %s\n' "$*" >&2; }
die()  { printf '[fetch-oga] error: %s\n' "$*" >&2; exit 1; }

require() {
    command -v "$1" >/dev/null 2>&1 \
        || die "'$1' is required but not on PATH. Install it and re-run."
}

# ---- argument parsing --------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ref)         REF="$2"; shift 2 ;;
        --ref=*)       REF="${1#*=}"; shift ;;
        --url)         UPSTREAM_URL="$2"; shift 2 ;;
        --url=*)       UPSTREAM_URL="${1#*=}"; shift ;;
        --local)       LOCAL_SRC="$2"; shift 2 ;;
        --local=*)     LOCAL_SRC="${1#*=}"; shift ;;
        --dest)        DEST_DIR="$2"; shift 2 ;;
        --dest=*)      DEST_DIR="${1#*=}"; shift ;;
        --force)       FORCE=1; shift ;;
        --verify)      VERIFY_ONLY=1; shift ;;
        --verbose)     VERBOSE=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "unknown option: $1 (try --help)" ;;
    esac
done

[[ ${VERBOSE} -eq 1 ]] && set -x

SENTINEL_REL="src/ort_genai_c.h"
STAMP_FILE="${DEST_DIR}/.stamp"

# ---- helpers -----------------------------------------------------------------
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
    local sentinel="${DEST_DIR}/${SENTINEL_REL}"
    if [[ ! -f "${sentinel}" ]]; then
        return 1
    fi
    if [[ ! -f "${DEST_DIR}/CMakeLists.txt" ]]; then
        warn "src/ort_genai_c.h exists but CMakeLists.txt is missing — incomplete checkout"
        return 2
    fi
    if [[ -f "${STAMP_FILE}" ]]; then
        local recorded actual
        recorded="$(awk -F= '$1=="sha256"{print $2}' "${STAMP_FILE}")"
        actual="$(sha256_of "${sentinel}")"
        if [[ -n "${recorded}" && "${recorded}" != "${actual}" ]]; then
            warn "recorded SHA-256 does not match on-disk sentinel (${recorded} != ${actual})"
            return 2
        fi
    fi
    return 0
}

write_stamp() {
    local source_desc="$1"
    local sentinel="${DEST_DIR}/${SENTINEL_REL}"
    local hash
    hash="$(sha256_of "${sentinel}")"
    {
        printf '# Written by %s; do not edit.\n' "${SCRIPT_NAME}"
        printf 'source=%s\n' "${source_desc}"
        if [[ "${source_desc}" == git:* ]]; then
            printf 'url=%s\n' "${UPSTREAM_URL}"
            printf 'ref=%s\n' "${REF}"
        elif [[ "${source_desc}" == local:* ]]; then
            printf 'local_path=%s\n' "${LOCAL_SRC}"
        fi
        printf 'sha256=%s\n' "${hash}"
        printf 'fetched_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "${STAMP_FILE}"
}

stamp_matches_request() {
    [[ -f "${STAMP_FILE}" ]] || return 1

    local recorded_url recorded_ref recorded_local
    recorded_url=$(awk -F= '$1=="url"{print $2}' "${STAMP_FILE}")
    recorded_ref=$(awk -F= '$1=="ref"{print $2}' "${STAMP_FILE}")
    recorded_local=$(awk -F= '$1=="local_path"{print $2}' "${STAMP_FILE}")

    if [[ -n "${LOCAL_SRC}" ]]; then
        [[ "${recorded_local}" == "${LOCAL_SRC}" ]]
    else
        [[ "${recorded_url}" == "${UPSTREAM_URL}" && "${recorded_ref}" == "${REF}" ]]
    fi
}

# ---- verify-only mode --------------------------------------------------------
if [[ ${VERIFY_ONLY} -eq 1 ]]; then
    if verify_dest; then
        log "verified: ${DEST_DIR}/${SENTINEL_REL}"
        exit 0
    fi
    die "verification failed for ${DEST_DIR}"
fi

# ---- idempotency check ------------------------------------------------------
if [[ ${FORCE} -ne 1 ]] && verify_dest && stamp_matches_request; then
    log "already staged at ${DEST_DIR}; use --force to re-fetch"
    exit 0
fi

if [[ ${FORCE} -ne 1 ]] && [[ -f "${STAMP_FILE}" ]] && verify_dest; then
    if [[ -n "${LOCAL_SRC}" ]]; then
        log "re-staging: --local ${LOCAL_SRC} differs from the last fetch"
    else
        log "re-fetching: requested ${UPSTREAM_URL}@${REF} differs from the last fetch"
    fi
fi

mkdir -p "${DEST_DIR}"
rm -f "${STAMP_FILE}"
require git
require tar

# ---- fetch -------------------------------------------------------------------
source_desc=""
if [[ -n "${LOCAL_SRC}" ]]; then
    LOCAL_SRC="$(cd "${LOCAL_SRC}" && pwd)" \
        || die "--local path does not exist: ${LOCAL_SRC}"
    if [[ ! -f "${LOCAL_SRC}/${SENTINEL_REL}" ]]; then
        die "no OGA source at ${LOCAL_SRC}. Expected ${SENTINEL_REL}."
    fi
    git -C "${LOCAL_SRC}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "--local must point to a git checkout so tracked sources can be staged safely"
    log "staging tracked files from local checkout: ${LOCAL_SRC}"
    find "${DEST_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    git -C "${LOCAL_SRC}" archive --format=tar HEAD | tar -xf - -C "${DEST_DIR}"
    source_desc="local:${LOCAL_SRC}"
else
    local_work="$(mktemp -d)"
    trap 'rm -rf "${local_work}"' EXIT

    log "cloning ${UPSTREAM_URL} at ${REF}"
    git -C "${local_work}" init -q
    git -C "${local_work}" remote add origin "${UPSTREAM_URL}"
    git -C "${local_work}" fetch --depth 1 origin "${REF}"
    git -C "${local_work}" checkout -q --detach FETCH_HEAD

    find "${DEST_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    git -C "${local_work}" archive --format=tar HEAD | tar -xf - -C "${DEST_DIR}"
    rm -rf "${local_work}"
    trap - EXIT
    source_desc="git:${UPSTREAM_URL}@${REF}"
fi

# Copy license if present.
if [[ -f "${DEST_DIR}/LICENSE" ]]; then
    log "LICENSE present"
fi

# ---- post-fetch verify ------------------------------------------------------
if ! verify_dest; then
    die "post-fetch verification failed. Inspect ${DEST_DIR}/${SENTINEL_REL} and re-run."
fi

write_stamp "${source_desc}"
log "staged ONNX Runtime GenAI at ${DEST_DIR}/${SENTINEL_REL}"
