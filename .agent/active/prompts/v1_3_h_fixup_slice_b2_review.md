# Review request — Lane H Slice B-2 (install.sh POSIX unit test)

You are the **reviewer (Codex)**. Verdict only: LGTM / NEEDS_CHANGES / BLOCK.
Max 3 rounds. Cite file paths + line ranges for any concern.

## Context

- Slice A LGTM commit: `0ad1b7c2` (retire rev-stealth-cli wrapper)
- Slice B-1 LGTM commit: `edc66bca` (release workflow hardening, workflow-only)
- Slice B-2 (this) = Delta 3 residue from Slice A — POSIX unit test for `install.sh`
- B-3 (Cargo mass rename + publish flips) is deliberately deferred to next driver
- baseline test count: 838 PASS / 0 fail (workflow + shell test only, no Rust delta expected)

## Scope of this slice

Files touched (exactly):
- `tests/install_sh_unit.sh` (new, 215 lines, pure POSIX sh)
- `.github/workflows/ci.yml` (added `install-sh-unit` job, PR-only)

Out of scope (do **not** require here):
- Cargo workspace renames (B-3)
- Brew formula / cosign / trivy workflow changes (already LGTM'd in B-1)

## What the test asserts

### `detect_target()` matrix (8 cases)
- `Linux/x86_64`   -> `x86_64-unknown-linux-musl`
- `Linux/aarch64`  -> `aarch64-unknown-linux-musl`
- `Linux/arm64`    -> `aarch64-unknown-linux-musl`
- `Darwin/x86_64`  -> `x86_64-apple-darwin`
- `Darwin/arm64`   -> `aarch64-apple-darwin`
- `FreeBSD/amd64`  -> die (unsupported)
- `Linux/i686`     -> die (unsupported)
- `MINGW64_NT/x86_64` -> die (windows unsupported)

### End-to-end with fake PATH (5 cases)
a. sha256 sidecar 404 -> warn + install ok (with `--no-verify`)
b. sha256 mismatch    -> die
c. cosign absent + default verify -> die ("cosign not installed")
d. cosign absent + `--no-verify` -> install ok (with SKIPPED warn)
e. cosign present + valid sig -> install ok ("cosign verification PASS")

## Technique

`install.sh` runs top-level code on source, so the test:
1. Carves function defs out via `awk` into a sourceable snippet for unit-level `detect_target` tests.
2. For e2e, builds a per-case sandbox with fake `uname`, `curl`, `cosign` on PATH and a real tarball fixture, then invokes `install.sh --version v0.0.0-test --prefix <sandbox>/prefix` so `resolve_version` is short-circuited and no sudo is needed.

`curl` parsing in the fake honors `-o <path>` and trailing URL; it serves fixtures based on URL suffix (`*.tar.gz` / `*.sha256` / `*.sig` / `*-keyless.pem`). The `bad_sha` mode produces a well-formed sidecar with a zero digest to drive `sha256 mismatch`.

## Local results (driver host: darwin-arm64)

```
$ shellcheck -s sh install.sh tests/install_sh_unit.sh
(no output; rc=0)

$ sh tests/install_sh_unit.sh
[1/2] detect_target() matrix
  ok   detect_target linux-x86_64
  ok   detect_target linux-aarch64
  ok   detect_target linux-arm64
  ok   detect_target darwin-x86_64
  ok   detect_target darwin-arm64
  ok   detect_target freebsd-amd64 (expected die)
  ok   detect_target linux-i686 (expected die)
  ok   detect_target windows-x86_64 (expected die)
[2/2] end-to-end behavior with fake PATH
  ok   sha256 sidecar missing -> warn + install ok
  ok   sha256 mismatch -> die
  ok   cosign absent + default verify -> die
  ok   cosign absent + --no-verify -> install ok
  ok   cosign present + valid sig -> install ok

Ran 13 tests, 0 failed.

$ dash tests/install_sh_unit.sh   # CI shell parity
Ran 13 tests, 0 failed.
```

YAML lint of `.github/workflows/ci.yml` via `python3 -c "import yaml; yaml.safe_load(...)"` passes.

## Review checklist (please verify)

1. **POSIX purity**: any bashism in `tests/install_sh_unit.sh`? (shellcheck `-s sh` + dash both pass locally)
2. **Coverage adequacy**: are detect_target + the 5 e2e branches the right minimal set, or is something load-bearing untested (e.g. PREFIX-not-writable / sudo path, `--version=` with `=`)?
3. **Test hygiene**: trap cleanup of `WORK_ROOT`, sandbox isolation per case (each in its own `${WORK_ROOT}/sb-<id>`), no leaking state across cases.
4. **CI job correctness**: PR-only gate matches sibling jobs (`distroless-pr-scan`), no main-branch noise, `sh` invocation (not `bash`) so dash is the runner.
5. **Risk to install.sh prod**: zero — install.sh is not modified.

## Sign-off format

If LGTM: respond exactly `LGTM` plus a one-line rationale.
If NEEDS_CHANGES: bullet list of required diffs (cite paths + lines).
If BLOCK: state the invariant violated.
