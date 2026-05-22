#!/usr/bin/env sh
# shellcheck shell=sh
# SPDX-License-Identifier: MIT
#
# Lane H.6 — `curl | sh` installer for rev-stealth.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/sasuketorii/rev_scraping/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/sasuketorii/rev_scraping/main/install.sh | sh -s -- --version v1.3.0
#   curl -fsSL https://raw.githubusercontent.com/sasuketorii/rev_scraping/main/install.sh | sh -s -- --prefix /opt/rev-stealth/bin
#   curl -fsSL https://raw.githubusercontent.com/sasuketorii/rev_scraping/main/install.sh | sh -s -- --no-verify  # skip cosign
#
# Security model:
#   - Downloads the release artifact + its `*.sig` + `*-keyless.pem` from
#     `https://github.com/sasuketorii/rev_scraping/releases/download/${VERSION}/`.
#   - Verifies with `cosign verify-blob` using a fixed certificate-identity
#     (GitHub Actions OIDC issuer pinned to the release workflow).
#   - Refuses to install if cosign is unavailable AND `--no-verify` was not
#     explicitly passed (fail-closed default).
#   - Tries `sha256` checksum as a secondary integrity gate.
#
# Strict POSIX sh; no bashisms. Validated under `shellcheck -s sh`.

set -eu

# ---------- defaults -------------------------------------------------------
REPO_OWNER="sasuketorii"
REPO_NAME="rev_scraping"
BIN_NAME="rev-stealth"
DEFAULT_VERSION="latest"
DEFAULT_PREFIX="/usr/local/bin"

# Cosign identity pin (matches release.yml workflow file path + ref).
# `release-please` rewrites the ref pin on each tag.
COSIGN_IDENTITY="https://github.com/${REPO_OWNER}/${REPO_NAME}/.github/workflows/release.yml@refs/tags/v"
COSIGN_OIDC_ISSUER="https://token.actions.githubusercontent.com"

VERSION="${REV_STEALTH_VERSION:-${DEFAULT_VERSION}}"
PREFIX="${REV_STEALTH_PREFIX:-${DEFAULT_PREFIX}}"
VERIFY="1"

# ---------- arg parse ------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --version)   VERSION="$2"; shift 2 ;;
        --version=*) VERSION="${1#*=}"; shift ;;
        --prefix)    PREFIX="$2"; shift 2 ;;
        --prefix=*)  PREFIX="${1#*=}"; shift ;;
        --no-verify) VERIFY="0"; shift ;;
        -h|--help)
            sed -n '/^# Usage:/,/^# Security model:/p' "$0" | sed 's/^# //; s/^#$//'
            exit 0
            ;;
        *)
            echo "install.sh: unknown arg: $1" >&2
            exit 64
            ;;
    esac
done

# ---------- helpers --------------------------------------------------------
log()  { printf '[install.sh] %s\n' "$*"; }
warn() { printf '[install.sh] WARN: %s\n' "$*" >&2; }
die()  { printf '[install.sh] ERROR: %s\n' "$*" >&2; exit 1; }

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

detect_target() {
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"
    case "${os}-${arch}" in
        linux-x86_64)   echo "x86_64-unknown-linux-musl" ;;
        linux-aarch64)  echo "aarch64-unknown-linux-musl" ;;
        linux-arm64)    echo "aarch64-unknown-linux-musl" ;;
        darwin-x86_64)  echo "x86_64-apple-darwin" ;;
        darwin-arm64)   echo "aarch64-apple-darwin" ;;
        *) die "unsupported platform: ${os}-${arch}" ;;
    esac
}

resolve_version() {
    if [ "${VERSION}" = "latest" ]; then
        need curl
        VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest" \
            | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' \
            | head -n 1)
        [ -n "${VERSION}" ] || die "could not resolve latest version"
    fi
    echo "${VERSION}"
}

# ---------- main -----------------------------------------------------------
need curl
need uname
need tar

TARGET="$(detect_target)"
VERSION="$(resolve_version)"
log "installing ${BIN_NAME} ${VERSION} for ${TARGET}"

TMPDIR_REAL="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_REAL}"' EXIT INT TERM

BASE_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${VERSION}"
ARCHIVE="${BIN_NAME}-${VERSION}-${TARGET}.tar.gz"

log "fetching ${BASE_URL}/${ARCHIVE}"
curl -fsSL --proto '=https' --tlsv1.2 -o "${TMPDIR_REAL}/${ARCHIVE}"     "${BASE_URL}/${ARCHIVE}"
curl -fsSL --proto '=https' --tlsv1.2 -o "${TMPDIR_REAL}/${ARCHIVE}.sha256" "${BASE_URL}/${ARCHIVE}.sha256" || warn "no sha256 sidecar"

# sha256 check (best-effort, soft-fail if sidecar absent).
if [ -s "${TMPDIR_REAL}/${ARCHIVE}.sha256" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
        ( cd "${TMPDIR_REAL}" && sha256sum -c "${ARCHIVE}.sha256" ) || die "sha256 mismatch"
    elif command -v shasum >/dev/null 2>&1; then
        ( cd "${TMPDIR_REAL}" && shasum -a 256 -c "${ARCHIVE}.sha256" ) || die "sha256 mismatch"
    else
        warn "no sha256sum / shasum available; skipping checksum gate"
    fi
    log "sha256 OK"
fi

# Cosign verification (fail-closed unless --no-verify).
if [ "${VERIFY}" = "1" ]; then
    if command -v cosign >/dev/null 2>&1; then
        curl -fsSL --proto '=https' --tlsv1.2 -o "${TMPDIR_REAL}/${ARCHIVE}.sig" "${BASE_URL}/${ARCHIVE}.sig"
        curl -fsSL --proto '=https' --tlsv1.2 -o "${TMPDIR_REAL}/${ARCHIVE}.cert" "${BASE_URL}/${ARCHIVE}-keyless.pem"
        # Pin to the *exact* tag in the identity to prevent workflow-rename
        # spoofing. Tag format is `v<semver>`.
        cosign verify-blob \
            --certificate-identity "${COSIGN_IDENTITY}${VERSION#v}" \
            --certificate-oidc-issuer "${COSIGN_OIDC_ISSUER}" \
            --signature "${TMPDIR_REAL}/${ARCHIVE}.sig" \
            --certificate "${TMPDIR_REAL}/${ARCHIVE}.cert" \
            "${TMPDIR_REAL}/${ARCHIVE}" \
            || die "cosign verify-blob FAILED — refusing to install"
        log "cosign verification PASS"
    else
        die "cosign not installed; install cosign (https://docs.sigstore.dev/cosign/installation/) or rerun with --no-verify"
    fi
else
    warn "cosign verification SKIPPED (--no-verify). Not recommended."
fi

# Extract + install. The release tarball is laid out as
#   rev-stealth-${VERSION}-${TARGET}/{rev-stealth,stealth-mcp,rev-auth,README,LICENSE}
# so we resolve the binary by find (handles dirname variations).
tar -xzf "${TMPDIR_REAL}/${ARCHIVE}" -C "${TMPDIR_REAL}"
EXTRACTED_BIN="$(find "${TMPDIR_REAL}" -type f -name "${BIN_NAME}" -perm -u+x -print -quit)"
[ -n "${EXTRACTED_BIN}" ] && [ -x "${EXTRACTED_BIN}" ] \
    || die "archive missing expected binary: ${BIN_NAME}"

if [ -w "${PREFIX}" ]; then
    install -m 0755 "${EXTRACTED_BIN}" "${PREFIX}/${BIN_NAME}"
else
    log "PREFIX ${PREFIX} not writable; using sudo"
    need sudo
    sudo install -m 0755 "${EXTRACTED_BIN}" "${PREFIX}/${BIN_NAME}"
fi

log "installed ${PREFIX}/${BIN_NAME}"
log "next steps: ${BIN_NAME} --help"
