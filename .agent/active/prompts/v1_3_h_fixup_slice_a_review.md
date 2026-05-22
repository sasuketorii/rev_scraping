# Lane H Fix-up Slice A — Reviewer Prompt (Round 1)

You are the **Codex reviewer** for Lane H Slice A. Verdict mode:
`LGTM` / `LGTM with nit` / `BLOCK <reason>`. Max 3 rounds.

## Scope of this slice (Slice A only)

Slice A retires the `rev-stealth-cli` publish-wrapper crate and migrates the
real CLI into a publishable `rev-stealth` package, keeping the workspace
directory `crates/stealth-cli/`. Slice B (separate dispatch) handles
publishing the transitive internal crates, supply-chain attestation,
external gate evidence, and tap-repo bootstrap automation.

Concretely, this slice contains **Delta 1** (lib refactor + name change) and
**Delta 6** (docs/distribution.md ADR + crates.io README). Deltas
2/3/4/5/7 are explicitly out of scope.

## Operator decisions you must accept as fixed

1. The wrapper crate `crates/rev-stealth-cli/` is retired (`git rm -r`).
2. `crates/stealth-cli/` keeps its directory; the `[package].name` is now
   `rev-stealth` with `publish = true`.
3. `cargo publish --dry-run -p rev-stealth --allow-dirty` is **not expected
   to PASS in Slice A**. The internal workspace crates remain
   `publish = false`, and the dry-run blocker (`no matching package named
   captcha-bypass found` etc.) is the deliberate handoff to Slice B. Do
   not BLOCK on this; verify the manifest is structurally publishable
   instead.
4. Cosign / OIDC attestation are Slice B.

## What to verify (deliverable acceptance)

### Delta 1 — lib refactor + name change

- `crates/stealth-cli/src/lib.rs` exports `pub fn run() -> i32` and
  `pub async fn run_async() -> i32`. `run` builds a multi-thread Tokio
  runtime and blocks on `run_async`.
- `crates/stealth-cli/src/main.rs` is a thin forwarder — single `main`
  function delegating to `stealth_cli::run()`. No business logic.
- `crates/stealth-cli/Cargo.toml`:
  - `[package].name = "rev-stealth"`
  - `[package].publish = true`
  - `description`, `repository`, `homepage`, `documentation`, `readme`,
    `keywords`, `categories` present.
  - `[lib] name = "stealth_cli"`, `path = "src/lib.rs"`.
  - `[[bin]] name = "rev-stealth"`, `path = "src/main.rs"`.
  - `cargo-deb` and `cargo-generate-rpm` metadata migrated from the
    deleted wrapper.
- Root `Cargo.toml`:
  - `crates/rev-stealth-cli` removed from `[workspace].members`.
  - `[workspace.dependencies]` internal entries all carry
    `version = "1.2.0"` alongside `path = ...` (required for the
    `rev-stealth` packaged manifest to satisfy "all dependencies must
    have a version requirement specified when publishing").
  - The internal alias is renamed from `stealth-cli` to `rev-stealth`.
- `crates/rev-stealth-cli/` directory deleted from the tree.
- `.github/workflows/release.yml`: every `-p rev-stealth-cli` is now
  `-p rev-stealth`; the path filter `crates/rev-stealth-cli/**` is now
  `crates/stealth-cli/**`. No stale wrapper references.
- `Formula/rev-stealth.rb`: still references `crates/stealth-cli` path
  (unchanged — the path didn't move). Note: the prompt's reference to
  `rev-stealth-cli-stub → rev-stealth` was a mis-statement; the Formula
  uses `path:`, not bin name, so no change is needed there. Confirm.
- `.github/workflows/docs.yml`: the `/api/index.html` redirect now points
  at `./stealth_cli/index.html` (the lib name with underscores), not the
  stale `./rev_stealth_cli/index.html`.

### Delta 6 — docs/distribution.md + crates.io README

- `docs/distribution.md` exists, ~150 lines, with:
  - Option A (Slice A) rationale (wrapper retirement + lib refactor).
  - Affected files list.
  - Release-cut runbook (tag push → external gate → SBOM → cosign → tap
    repo bootstrap).
  - Slice B handoff (publish chain, attestation, external evidence).
- `crates/stealth-cli/README.md` exists as the crates.io landing page:
  - `cargo install --locked rev-stealth`
  - `rev-stealth --help`
  - Prerequisites (Rust 1.83+, Chrome 120+, keystore).
  - v1.2 + v1.3 (Lane G) feature summary.
  - LICENSE / homepage / repo links.

## Deterministic checks the driver ran

| Check                                                   | Result                              |
| ------------------------------------------------------- | ----------------------------------- |
| `cargo check --workspace`                               | Finished dev (clean)                |
| `cargo clippy --workspace --no-deps -- -D warnings`     | Finished dev (clean)                |
| `cargo build --release --bin rev-stealth`               | OK                                  |
| `./target/release/rev-stealth --help`                   | Lists captcha/browser/vpn/... cmds  |
| `cargo test --workspace --no-fail-fast`                 | 795 passed, 0 failed                |
| `cargo publish --dry-run -p rev-stealth --allow-dirty`  | Blocked on Slice B (see above)      |

Test count baseline before this slice was 791; the +4 comes from doctests
exposed by the new `lib.rs` surface (`run`, `run_async`).

## Files touched (driver-authored, Slice A only)

- `Cargo.toml` (workspace members + dependencies)
- `crates/stealth-cli/Cargo.toml`
- `crates/stealth-cli/src/lib.rs`
- `crates/stealth-cli/src/main.rs`
- `crates/stealth-cli/README.md` (new)
- `crates/stealth-sanitize/Cargo.toml` (stale comment about
  `rev-stealth-cli` removed)
- `crates/rev-stealth-cli/` deleted (3 files removed)
- `.github/workflows/release.yml`
- `.github/workflows/docs.yml`
- `docs/distribution.md` (new)

## Out-of-scope (Slice B handoff)

- Flipping internal crates (`stealth-core`, `captcha-bypass`, `vpn-rotate`,
  `mobile-fp`, `obscura-bridge`, `stealth-cf`, `stealth-parse`,
  `stealth-sites`, `stealth-auth` + transitive) to `publish = true` with
  publishable metadata.
- `cargo publish --dry-run` actually passing in CI.
- Cosign keyless OIDC attestation (`actions/attest-build-provenance`,
  `id-token: write`).
- SBOM (CycloneDX) generation pipeline.
- Homebrew tap-repo (`sasuketorii/homebrew-rev-stealth`) bootstrap.
- External gate evidence layout at `.github/release-evidence/v1.3.0/`.

## Verdict request

Emit one of:

```
LGTM
LGTM with nit: <one-line nit description>
BLOCK <severity>: <reason>
```

If BLOCK, list the file:line of the blocker and the specific Slice A
requirement it violates. Do not block on Slice B scope.
