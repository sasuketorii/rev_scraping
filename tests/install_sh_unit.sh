#!/bin/sh
# shellcheck shell=sh
# SPDX-License-Identifier: MIT
#
# Lane H Slice B-2 — POSIX unit test for install.sh.
#
# Verifies:
#   1. detect_target() returns the correct triple for every supported
#      (os, arch) pair, and dies on unsupported combos.
#   2. End-to-end script behavior under a PATH of fake binaries:
#      a. sha256 sidecar missing -> warn, install succeeds (with --no-verify).
#      b. sha256 mismatch -> die.
#      c. cosign absent + verify on (default) -> die.
#      d. cosign absent + --no-verify -> install succeeds (with warn).
#      e. cosign present + valid sig -> install succeeds.
#
# Pure POSIX sh; no BATS, no bashisms. Validated by `shellcheck -s sh`.
#
# Run:
#     sh tests/install_sh_unit.sh

set -eu

unset CDPATH
# Pin PATH to standard locations so that `rm`, `mkdir`, `awk`, `grep`, `tar`,
# `mktemp`, and `sed` resolve to system tools even when this script is run
# from a workspace that injects its own wrappers earlier on PATH. The fake
# PATH used by the e2e cases is scoped to the inner `sh -c` invocation only;
# the outer shell (including trap/cleanup) always uses the path below.
PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:${PATH}}"
export PATH

REPO_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

# Discovery sanity --------------------------------------------------------
[ -f "${INSTALL_SH}" ] || { echo "FAIL: ${INSTALL_SH} not found" >&2; exit 1; }

# Test harness ------------------------------------------------------------
TESTS_RUN=0
TESTS_FAIL=0
WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "${WORK_ROOT}" 2>/dev/null || :' EXIT INT TERM

pass() { TESTS_RUN=$((TESTS_RUN + 1)); printf '  ok   %s\n' "$1"; }
fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAIL=$((TESTS_FAIL + 1))
    printf '  FAIL %s\n' "$1" >&2
    if [ -n "${2:-}" ]; then
        printf '       %s\n' "$2" >&2
    fi
}

# ---------- Extract function definitions for unit-level testing ---------
# install.sh has top-level executable code; we can't `.` it directly.
# Carve out only the function blocks ("^log()", "^warn()", "^die()",
# "^need()", "^detect_target()", "^resolve_version()") into a sourceable
# snippet. The carving uses sed with awk-like ranges over function braces.
extract_functions() {
    snippet="${WORK_ROOT}/install_sh_funcs.sh"
    awk '
        /^log\(\)/  || /^warn\(\)/ || /^die\(\)/ ||
        /^need\(\)/ || /^detect_target\(\)/ || /^resolve_version\(\)/ {
            in_fn = 1
        }
        in_fn { print }
        in_fn && /^\}$/ { in_fn = 0 }
    ' "${INSTALL_SH}" > "${snippet}"
    echo "${snippet}"
}

FUNCS_SNIPPET="$(extract_functions)"

# Sanity: snippet must define detect_target.
grep -q '^detect_target()' "${FUNCS_SNIPPET}" \
    || { echo "FAIL: could not extract functions from install.sh" >&2; exit 1; }

# ---------- detect_target() table-driven test ---------------------------
check_target() {
    label="$1"
    fake_os="$2"
    fake_arch="$3"
    expected="$4"   # empty => expect die()

    sandbox="${WORK_ROOT}/sandbox-detect-$$-${TESTS_RUN}"
    mkdir -p "${sandbox}/bin"
    # Fake uname that honors -s and -m
    cat > "${sandbox}/bin/uname" <<EOF
#!/bin/sh
case "\$1" in
    -s) printf '%s\n' "${fake_os}"  ;;
    -m) printf '%s\n' "${fake_arch}" ;;
    *)  printf '%s\n' "${fake_os}"  ;;
esac
EOF
    chmod +x "${sandbox}/bin/uname"

    # tr / sed must remain available; prepend sandbox.
    out="$(PATH="${sandbox}/bin:${PATH}" sh -c ". '${FUNCS_SNIPPET}'; detect_target" 2>&1)" \
        && rc=0 || rc=$?

    if [ -n "${expected}" ]; then
        if [ "${rc}" -eq 0 ] && [ "${out}" = "${expected}" ]; then
            pass "detect_target ${label}"
        else
            fail "detect_target ${label}" "rc=${rc} out=${out} expected=${expected}"
        fi
    else
        # Expect failure (die).
        if [ "${rc}" -ne 0 ]; then
            pass "detect_target ${label} (expected die)"
        else
            fail "detect_target ${label}" "expected die, got rc=0 out=${out}"
        fi
    fi
    rm -rf "${sandbox}" 2>/dev/null || :
}

echo "[1/2] detect_target() matrix"
check_target "linux-x86_64"    "Linux"   "x86_64"  "x86_64-unknown-linux-musl"
check_target "linux-aarch64"   "Linux"   "aarch64" "aarch64-unknown-linux-musl"
check_target "linux-arm64"     "Linux"   "arm64"   "aarch64-unknown-linux-musl"
check_target "darwin-x86_64"   "Darwin"  "x86_64"  "x86_64-apple-darwin"
check_target "darwin-arm64"    "Darwin"  "arm64"   "aarch64-apple-darwin"
check_target "freebsd-amd64"   "FreeBSD" "amd64"   ""
check_target "linux-i686"      "Linux"   "i686"    ""
check_target "windows-x86_64"  "MINGW64_NT-10.0" "x86_64" ""

# ---------- End-to-end behavior with fake PATH --------------------------
# Build a per-case sandbox with:
#   - fake curl that copies fixture bytes into the requested output path
#   - fake tar that materializes ${BIN_NAME} at the extraction root
#   - optional fake cosign that either succeeds or is absent
#   - PREFIX writable temp dir so no sudo
#
# We invoke install.sh with --version vX.Y.Z to short-circuit resolve_version,
# and with --prefix pointing into the sandbox.

ARCHIVE_FIXTURE_BIN_CONTENT='#!/bin/sh
echo "rev-stealth fake"
'

setup_e2e_sandbox() {
    sb="$1"
    mkdir -p "${sb}/bin" "${sb}/prefix" "${sb}/fixture"

    # Build a real tar.gz with a fake rev-stealth binary inside the expected dir.
    fixture_root="${sb}/fixture"
    inner_dir="${fixture_root}/rev-stealth-v0.0.0-test-x86_64-unknown-linux-musl"
    mkdir -p "${inner_dir}"
    printf '%s' "${ARCHIVE_FIXTURE_BIN_CONTENT}" > "${inner_dir}/rev-stealth"
    chmod +x "${inner_dir}/rev-stealth"
    ( cd "${fixture_root}" && tar -czf archive.tar.gz "$(basename "${inner_dir}")" )
    # Pre-compute sha256 for the archive (use shasum if sha256sum missing).
    if command -v sha256sum >/dev/null 2>&1; then
        ( cd "${fixture_root}" && sha256sum archive.tar.gz \
            | sed 's| archive\.tar\.gz| rev-stealth-v0.0.0-test-x86_64-unknown-linux-musl.tar.gz|' \
            > archive.sha256 )
    else
        ( cd "${fixture_root}" && shasum -a 256 archive.tar.gz \
            | sed 's| archive\.tar\.gz| rev-stealth-v0.0.0-test-x86_64-unknown-linux-musl.tar.gz|' \
            > archive.sha256 )
    fi

    # Force the target triple to one we built the fixture for: a fake
    # uname that always reports linux/x86_64.
    cat > "${sb}/bin/uname" <<'EOF'
#!/bin/sh
case "$1" in
    -s) echo "Linux"   ;;
    -m) echo "x86_64"  ;;
    *)  echo "Linux"   ;;
esac
EOF
    chmod +x "${sb}/bin/uname"
}

# Mode selector: $1 = mode for fake curl behavior
#   "ok"           -> serve archive + sha256 sidecar (matching)
#   "no_sha"       -> serve archive but 404 on sha256
#   "bad_sha"      -> serve archive + sha256 sidecar with wrong digest
make_fake_curl() {
    sb="$1"
    mode="$2"
    cat > "${sb}/bin/curl" <<EOF
#!/bin/sh
# Fake curl: parses -o <out> and trailing URL, then serves from fixture/.
set -eu
out=""
url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o)        out="\$2"; shift 2 ;;
        -f|-s|-S|-L|-fsSL) shift ;;
        --proto|--tlsv1.2) shift ;;
        --proto=*|--tlsv1.2=*) shift ;;
        -*)        shift ;;
        *)         url="\$1"; shift ;;
    esac
done
fx='${sb}/fixture'
case "\$url" in
    *.tar.gz)         cp "\$fx/archive.tar.gz" "\$out" ;;
    *.tar.gz.sha256)
        case "${mode}" in
            ok)      cp "\$fx/archive.sha256" "\$out" ;;
            bad_sha)
                # Wrong digest, but well-formed.
                printf '0000000000000000000000000000000000000000000000000000000000000000  rev-stealth-v0.0.0-test-x86_64-unknown-linux-musl.tar.gz\n' > "\$out"
                ;;
            no_sha)  exit 22 ;;
        esac
        ;;
    *.sig)            : > "\$out" ;;
    *-keyless.pem)    : > "\$out" ;;
    *)                exit 22 ;;
esac
EOF
    chmod +x "${sb}/bin/curl"
}

make_fake_cosign_ok() {
    sb="$1"
    cat > "${sb}/bin/cosign" <<'EOF'
#!/bin/sh
# Pretend verify-blob always passes.
exit 0
EOF
    chmod +x "${sb}/bin/cosign"
}

# Run install.sh inside sandbox; capture rc + combined output.
run_install() {
    sb="$1"
    shift
    PATH="${sb}/bin:/usr/bin:/bin" \
        sh "${INSTALL_SH}" \
            --version v0.0.0-test \
            --prefix "${sb}/prefix" \
            "$@" \
        > "${sb}/out.log" 2>&1
}

echo "[2/2] end-to-end behavior with fake PATH"

# (a) sha256 sidecar missing -> warn, but install succeeds (with --no-verify).
SB="${WORK_ROOT}/sb-a"
setup_e2e_sandbox "${SB}"
make_fake_curl "${SB}" "no_sha"
if run_install "${SB}" --no-verify; then
    if [ -x "${SB}/prefix/rev-stealth" ]; then
        if grep -q "no sha256 sidecar" "${SB}/out.log"; then
            pass "sha256 sidecar missing -> warn + install ok"
        else
            fail "sha256 sidecar missing" "expected warn line; log=$(cat "${SB}/out.log")"
        fi
    else
        fail "sha256 sidecar missing" "binary not installed; log=$(cat "${SB}/out.log")"
    fi
else
    fail "sha256 sidecar missing" "install exited non-zero; log=$(cat "${SB}/out.log")"
fi

# (b) sha256 mismatch -> die.
SB="${WORK_ROOT}/sb-b"
setup_e2e_sandbox "${SB}"
make_fake_curl "${SB}" "bad_sha"
if run_install "${SB}" --no-verify; then
    fail "sha256 mismatch -> die" "install unexpectedly succeeded; log=$(cat "${SB}/out.log")"
else
    if grep -q "sha256 mismatch" "${SB}/out.log"; then
        pass "sha256 mismatch -> die"
    else
        fail "sha256 mismatch -> die" "wrong error; log=$(cat "${SB}/out.log")"
    fi
fi

# (c) cosign absent + verify on (default) -> die.
SB="${WORK_ROOT}/sb-c"
setup_e2e_sandbox "${SB}"
make_fake_curl "${SB}" "ok"
# Intentionally no cosign in sandbox.
if run_install "${SB}"; then
    fail "cosign absent default -> die" "install unexpectedly succeeded; log=$(cat "${SB}/out.log")"
else
    if grep -q "cosign not installed" "${SB}/out.log"; then
        pass "cosign absent + default verify -> die"
    else
        fail "cosign absent + default verify -> die" "wrong error; log=$(cat "${SB}/out.log")"
    fi
fi

# (d) cosign absent + --no-verify -> install ok (with warn).
SB="${WORK_ROOT}/sb-d"
setup_e2e_sandbox "${SB}"
make_fake_curl "${SB}" "ok"
if run_install "${SB}" --no-verify; then
    if [ -x "${SB}/prefix/rev-stealth" ] \
        && grep -q "cosign verification SKIPPED" "${SB}/out.log"; then
        pass "cosign absent + --no-verify -> install ok"
    else
        fail "cosign absent + --no-verify -> install ok" "log=$(cat "${SB}/out.log")"
    fi
else
    fail "cosign absent + --no-verify -> install ok" "install failed; log=$(cat "${SB}/out.log")"
fi

# (e) cosign present + valid sig -> install ok.
SB="${WORK_ROOT}/sb-e"
setup_e2e_sandbox "${SB}"
make_fake_curl "${SB}" "ok"
make_fake_cosign_ok "${SB}"
if run_install "${SB}"; then
    if [ -x "${SB}/prefix/rev-stealth" ] \
        && grep -q "cosign verification PASS" "${SB}/out.log"; then
        pass "cosign present + valid sig -> install ok"
    else
        fail "cosign present + valid sig -> install ok" "log=$(cat "${SB}/out.log")"
    fi
else
    fail "cosign present + valid sig -> install ok" "install failed; log=$(cat "${SB}/out.log")"
fi

# ---------- Report ------------------------------------------------------
echo ""
echo "Ran ${TESTS_RUN} tests, ${TESTS_FAIL} failed."
[ "${TESTS_FAIL}" -eq 0 ] || exit 1
