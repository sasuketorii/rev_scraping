# release-binary-privacy-scan.sh — I-2b Reference

> Operator + CI reference for `scripts/ci/release-binary-privacy-scan.sh`,
> the enforcement tool for **I-2b (shipped binary privacy stable)**.
> Distribution-grade guarantee: the shipped `semantic-mcp` binary must not
> embed any host-identifying path or in-house project marker.

## 1. Purpose — the I-2b invariant

I-2b (defined in `AGENTS.md` around L128, "Binary privacy stable") requires
the shipped Rust binary `harness-rust/target/release/semantic-mcp` to scan
clean against the following effective check:

```
strings <binary> | grep -E '/Users/|/home/|contact_dev|.cargo/registry/src|.rustup/toolchains'
```

The expected result is **0 hits**. Any single hit means the artifact leaks
the build host's username, home root, Cargo registry path, rustup toolchain
path, or the upstream development project marker (`contact_dev`), and the
artifact MUST NOT be shipped.

`scripts/ci/release-binary-privacy-scan.sh` is the only authoritative
enforcement tool for this invariant. It is the T-H-4 / T-H-4a / T-H-4b
deliverable and runs before release tagging. It does not modify source,
does not stage commits, and does not push tags. It only builds (optionally),
scans, emits metrics, and returns an exit code.

## 2. The true problem — rustc panic-location debug strings

The leak is not symbol-table content. It is **referenced data strings**
embedded by rustc and dependencies for panic-location reporting. With a
default release profile, rustc emits the full source path of every reachable
`panic!()` site (and every `unwrap`, `expect`, slice bounds check, etc.) as
a string literal in the binary. These typically include:

- dependency source paths under `~/.cargo/registry/src/...` (e.g. `chrono`,
  `regex-automata`, `tracing-subscriber`, and other deps with reachable
  panic paths),
- standard-library source paths under `~/.rustup/toolchains/.../lib/rustlib/src/...`
  (`core`, `alloc`, `std`),
- repo-local paths for the in-tree crate sources.

Because these are referenced data, **`strip = "symbols"` does not remove
them**: stripping only touches symbol-table entries, not string literals
held by live code. Historical measurement of a strip-only release build
produced roughly **92 literal-username-bearing hits**. The only effective
fix is `--remap-path-prefix`, which rewrites the paths at compile time so
the binary never sees the host-specific form.

## 3. CLI surface

The script intentionally exposes a tiny surface.

| Flag | Argument | Behavior |
|---|---|---|
| `--rebuild` | none | Run a privacy build (`cargo build --release -p semantic-mcp` with privacy `RUSTFLAGS`) before scanning. |
| `--binary <path>` | path | Scan an arbitrary binary. Suppresses both auto-build (when the file is missing) and auto-rebuild-on-leak. |
| `-h`, `--help` | none | Print usage. |
| (default) | — | Scan the default binary `harness-rust/target/release/semantic-mcp`. If absent, run a privacy build first. If leak is detected, auto-rebuild once and rescan. |

There is **no `--json` flag, no dry-run flag, no commit/stage/tag
operation**. JSONL metrics are emitted unconditionally.

## 4. Implementation — two-layer RUSTFLAGS model

Privacy hardening is split between persisted Cargo config and runtime
script-computed flags. The split is intentional and load-bearing.

### Layer A — persisted host-agnostic flags

Location: `harness-rust/.cargo/config.toml`, `[build].rustflags`.

```toml
[build]
rustflags = [
  "-C", "strip=symbols",
  "--remap-path-prefix=/Users/=",
  "--remap-path-prefix=/home/=",
]
```

Layer A applies to **every** `cargo build` invocation, including a bare
`cargo build --release` by a developer. It coarsely collapses the macOS
and Linux home roots so the literal username does not appear.

Layer A intentionally does **not** include `$HOME`, `$CARGO_HOME`, or
`$RUSTUP_HOME` because:

- Cargo does **not** expand environment variables inside `rustflags`
  arrays; a literal `$HOME` would be passed verbatim to rustc and have
  no effect.
- Hardcoding a real username would itself be a privacy leak the moment
  this file is published.

Layer A therefore cannot eliminate the Cargo registry tail
(`.cargo/registry/src/...`) or the rustup toolchain tail
(`.rustup/toolchains/...`).

### Layer B — runtime host-dependent flags

Location: `privacy_rustflags()` inside the scan script.

The script resolves the host-specific roots at invocation time and appends
remap flags to any inherited `RUSTFLAGS`:

| Source prefix (resolved at runtime) | Remapped to |
|---|---|
| `$HOME` | `~` |
| `${CARGO_HOME:-$HOME/.cargo}/registry/src` | `cargo-registry-src` |
| `${RUSTUP_HOME:-$HOME/.rustup}/toolchains` | `rustup-toolchains` |
| `<repo_root>` (the rev_harness checkout) | `rev-harness-src` |

The build invocation is effectively:

```
( cd harness-rust && RUSTFLAGS="${RUSTFLAGS:-} <privacy flags>" \
    cargo build --release -p semantic-mcp )
```

The build log is captured to a tempfile. On failure the log is run through
the redaction pipeline and streamed to stderr, then the script exits 1.

## 5. Scan algorithm

1. Resolve target binary (default or `--binary`).
2. If the default binary is missing **or** `--rebuild` was passed, run
   the Layer A+B privacy build.
3. Require the `strings` tool; abort with exit 1 if absent.
4. `strings <binary> > <tmp>/strings.txt`.
5. For each of the five fixed patterns (literal `grep -F`, in this exact
   order), count matches and accumulate.
6. If the default binary leaks and `--binary` was not used, **auto-rebuild
   once** and rescan a single time.
7. Emit a JSONL record (`result: "ok"` or `result: "leak"`) and exit.

### Scan patterns (load-bearing, do not reorder)

| # | Literal pattern | Why it leaks identity |
|---|---|---|
| 1 | `/Users/` | macOS home root + username. |
| 2 | `/home/` | Linux home root + username. |
| 3 | `.cargo/registry/src/` | Cargo registry source cache (dep panic-locations). |
| 4 | `.rustup/toolchains/` | rustup toolchain source (std panic-locations). |
| 5 | `contact_dev` | Upstream dev project marker; release binary must not name it. |

On leak, the script prints up to **three** sample lines per matched pattern
to stderr, all passed through the redaction pipeline.

## 6. Exit codes

| Exit | Meaning | JSONL emitted? |
|---|---|---|
| `0` | Clean scan; I-2b satisfied for this binary. | yes, `result: "ok"` |
| `1` | Leak detected; or privacy build failed; or `strings` missing; or binary missing. | only on confirmed leak, `result: "leak"` |
| `2` | Usage error (unknown flag, missing `--binary` argument). | no |

Operators must preserve the distinction between "confirmed leak"
(exit 1 + JSONL leak event) and "operational failure" (exit 1 without
a JSONL event) when filing incidents.

## 7. JSONL metrics output

Path: `.agent/metrics/release_binary_privacy_scan.jsonl` (always created
under `repo_root/.agent/metrics/`, append-only).

Schema id: `release-binary-privacy-scan/v1`.

| Field | Type | Notes |
|---|---|---|
| `ts` | string | UTC ISO-8601 timestamp. |
| `event` | string | Always `release_binary_privacy_scan`. |
| `schema` | string | `release-binary-privacy-scan/v1`. |
| `binary_path` | string | Repo-relative path when inside `repo_root`; otherwise the literal `<REDACTED_HOST_PATH>`. Never a raw host path. |
| `scan_patterns` | array<string> | The five literal scan patterns, in canonical order. |
| `hits` | integer | Total hit count across all patterns. |
| `result` | string | `ok` or `leak`. |

Sample record (clean run, default binary):

```json
{"ts":"2026-05-26T00:00:00Z","event":"release_binary_privacy_scan","schema":"release-binary-privacy-scan/v1","binary_path":"harness-rust/target/release/semantic-mcp","scan_patterns":["/Users/","/home/",".cargo/registry/src/",".rustup/toolchains/","contact_dev"],"hits":0,"result":"ok"}
```

The JSONL file is audit evidence only; the binary scan result itself is
the enforcement signal.

## 8. Redaction behavior

A `sed` pipeline is applied to every operator-visible string before it
reaches stderr: leak preview lines and build-log failure output. Classes
replaced with the literal token `<REDACTED_HOST_PATH>`:

- macOS-style paths beginning with `/Users/`
- Linux-style paths beginning with `/home/`
- `…/.cargo/registry/src/…`
- `…/.rustup/toolchains/…`

Operators MUST NOT paste raw `strings` output into issue trackers, chat,
or commit messages. If manual inspection is required, route the output
through the same redaction or replace prefixes by hand.

## 9. Cargo release profile context

`harness-rust/Cargo.toml`:

```toml
[profile.release]
strip = "symbols"
panic = "abort"
lto = "fat"
codegen-units = 1
opt-level = 3

[profile.release.package."*"]
strip = "symbols"
```

These settings reduce binary size and improve runtime characteristics,
but **none of them satisfy I-2b on their own**. `strip = "symbols"` does
not touch panic-location string literals; `panic = "abort"` does not
remove emitted location strings (the strings are present at every
panic-able call site, not only at unwind handlers); `lto = "fat"` may
drop some unused data but is not a privacy guarantee. Acceptance is
defined by the scan result, not by profile intent.

## 10. CI wiring

- **`scripts/ci/hsdi-phase-H-done.sh`** step 4 (T-H-4 acceptance):
  ```
  bash scripts/ci/release-binary-privacy-scan.sh \
    && bash test/unit/test-release-binary-privacy.sh
  ```
- **`scripts/ci/phase-done-smoke.sh`** resolves the scan command as
  ```
  PRIVACY_SCAN_CMD="${REV_HARNESS_PRIVACY_SCAN:-$REPO_ROOT/scripts/ci/release-binary-privacy-scan.sh}"
  ```
  The `REV_HARNESS_PRIVACY_SCAN` env var exists so unit tests can inject
  a stub; **production release gating must never set it**.
- **I-12 linkage**: agent-only dual-LGTM is provisional. A final verdict
  requires `phase-done-smoke.sh` to exit 0, and because the privacy scan
  sits inside that smoke path, I-2b is part of final release gating.
- Release tag operations MUST follow a successful scan; no tag may be
  pushed against an artifact that did not emit a JSONL `result: "ok"`
  record for the exact build under test.

## 11. Failure recovery runbook

When CI fails on the privacy scan, follow this sequence:

1. Drop stale incremental artifacts:
   ```bash
   ( cd harness-rust && cargo clean -p semantic-mcp )
   ```
2. Re-run with a forced privacy build:
   ```bash
   bash scripts/ci/release-binary-privacy-scan.sh --rebuild
   ```
3. If still leaking, identify the offending pattern (output is redacted
   only by the script's own pipeline; redact manually before sharing):
   ```bash
   strings harness-rust/target/release/semantic-mcp \
     | grep -F '.cargo/registry/src/' | head -10
   ```
4. Diagnose by pattern class:
   - Cargo registry tail → a newly added dependency introduced panic
     locations under an unmapped registry root. Verify
     `CARGO_HOME`/`HOME` env in CI; add a `--remap-path-prefix` for any
     non-standard registry mirror.
   - Rustup toolchain tail → custom toolchain or non-default
     `RUSTUP_HOME`; export the variable before invoking the script.
   - Repo-root tail → `<repo_root>` remap did not match (e.g. symlink
     resolution, alternate checkout path). Re-run from the canonical
     checkout root.
   - `contact_dev` → an in-tree source constant, fixture, or path
     literal references the upstream dev project. Remove or
     parameterize it.
5. Do **not** "fix" by removing the scan, suppressing the pattern,
   relaxing the exit code, or substituting a plain `cargo build`.

## 12. Partial coverage trade-off

| Build path | Coverage | Recommended use |
|---|---|---|
| Plain `cd harness-rust && cargo build --release -p semantic-mcp` | Layer A only — literal username collapses, but `.cargo/registry/src/` tail (~92 hits historical) remains. | Local development only. **NOT release evidence.** |
| `bash scripts/ci/release-binary-privacy-scan.sh [--rebuild]` | Layer A + Layer B — all five patterns must be 0. | Authoritative production-release build. Required for I-2b acceptance. |

Release tagging must rely on the script path. Reviewer notes, provisional
dual-LGTM, or local "looks clean" inspection do not substitute for an
exit-0 JSONL `result: "ok"` record from this script.

## 13. Operator quickstart

```bash
# Default scan (auto-build if binary missing; auto-rebuild once on leak)
bash scripts/ci/release-binary-privacy-scan.sh

# Force a fresh privacy build, then scan
bash scripts/ci/release-binary-privacy-scan.sh --rebuild

# Scan an arbitrary artifact (no auto-rebuild)
bash scripts/ci/release-binary-privacy-scan.sh --binary <path-to-binary>

# Usage text
bash scripts/ci/release-binary-privacy-scan.sh --help

# Tail recent scan outcomes
tail -n 20 .agent/metrics/release_binary_privacy_scan.jsonl

# Paired unit test (used by phase-H done step 4)
bash test/unit/test-release-binary-privacy.sh
```

Expected clean operator state: exit code `0`, JSONL `result: "ok"`,
`hits: 0`, no stderr leak report.

Expected leak operator state: exit code `1`, JSONL `result: "leak"`,
`hits > 0`, stderr includes redacted sample lines per matched pattern.

## 14. Cross-references

| Topic | Location |
|---|---|
| I-2b invariant text ("Binary privacy stable") | `AGENTS.md` (around L128) |
| I-2 (Tier 1 capsule byte-stable) — I-2b complements it by guarding the **shipped artifact** vs. the in-process capsule bytes | `AGENTS.md` (same invariants block) |
| I-12 (smoke-gated dual-LGTM) | `AGENTS.md` (around L133) |
| Scan script (this manual) | `scripts/ci/release-binary-privacy-scan.sh` |
| Phase H acceptance step | `scripts/ci/hsdi-phase-H-done.sh` (step 4) |
| Smoke gate | `scripts/ci/phase-done-smoke.sh` |
| Paired unit test | `test/unit/test-release-binary-privacy.sh` |
| Cargo release profile | `harness-rust/Cargo.toml` (`[profile.release]`) |
| Persisted Layer-A `rustflags` | `harness-rust/.cargo/config.toml` |

Operator rule of thumb: a release artifact is acceptable for I-2b **only**
when this script exits `0` and emits a `result: "ok"` JSONL record for the
exact binary being shipped. A clean ordinary `cargo build`, a passing
reviewer note, or a provisional dual-LGTM is not enough.
