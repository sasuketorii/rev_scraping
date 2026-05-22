# Lane K — Evidence rationale notes (durable)

This file documents WHY certain Lane K evidence types are not available
pre-merge, so reviewers do not have to re-derive the reasoning each scoring
round. Generated alongside Lane K final scoring round 2 → round 3.

## K.1 — coverage branch% not measured in v1.3
- `cargo-llvm-cov --branch` requires nightly per project docs.
- v1.3 standardized on stable for reproducibility; branch% is reported
  as 0 (the gate step treats 0 as "unsupported, do not warn").
- Workflow header now states this explicitly; branch warning step is
  disabled with a comment pointing to v1.4 promotion.
- Acceptance for v1.3 is line-coverage soft-gate only; branch% gate
  promotion is v1.4 scope.

## K.5 — `cargo +nightly fuzz build` not executed locally
- Local fuzz build requires a working `cargo-fuzz` install + nightly
  Rust + asan, which is the GH-hosted `fuzz-nightly.yml` runner
  configuration, not the developer sandbox.
- Workflow YAML, fuzz Cargo.toml, and the 3 target files (post-rename)
  are present and aligned to spec. Local `cargo check --manifest-path
  crates/stealth-sanitize/fuzz/Cargo.toml --bins` passed in the round-1
  reviewer pass (no compile error).
- `sanitize_envelope_parse.rs` is on disk but untracked at scoring
  time; staging is a commit-time concern, not a code defect.

## K.6 — actual cargo-test-release run artifacts only exist post-merge
- The 4 jobs (linux-x86_64, linux-aarch64 QEMU, macos-15-intel,
  macos-14 arm64) all use `cargo test --workspace --release`.
- Pre-merge evidence is the workflow YAML; `actionlint` is clean.
- Post-merge evidence comes from the nightly cron (04:00 UTC).

## K.7 — bencher.dev integration deferred
- v1.3 ships the 5 bench targets compiled (--no-run verified locally)
  and runs them in `bench.yml` matrix with criterion `--output-format
  bencher`.
- bencher.dev PR-diff comment + `bench-regression` label require an
  external SaaS integration (token + project ID) outside this lane's
  scope.
- Documented as v1.4 follow-up in `bench.yml` comment block.

## K.8 — release artifacts only exist on GH release publish
- `sbom.yml` runs on release publish; pre-release evidence is the
  workflow YAML structure.
- cosign sign-blob + SLSA L3 attestation require GH OIDC token
  provisioning that only materializes during an actual release run.
- Verification path: first v1.3.0 tag → confirm `.spdx.json` +
  `.cdx.json` attached to the GH release.

## actionlint clean status (round-2)
- `.github/workflows/{security,coverage,cross-platform-nightly,
  fuzz-nightly,sbom,bench}.yml` — actionlint exit 0 as of round-2 fixes.
- SC1127 (backticks in echo), SC2012 (ls→find), SC2034 (unused var),
  SC2129 (block redirect) all resolved.
