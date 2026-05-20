# v1.1.0 GA Release Checklist

This checklist is the deterministic gate for the v1.1.0 GA tag. Do not push the
GA tag unless every GA Gate item is either complete or explicitly escalated with
a documented release-manager decision.

## GA Gate (24 items)

- [ ] workspace test count >= 500 PASS (current: 519)
- [ ] `cargo test --workspace --no-fail-fast` 0 fail
- [ ] `cargo clippy --workspace --all-targets -- -D warnings` clean
- [ ] `bash scripts/check_source_and_spdx.sh` PASS
- [ ] `cargo deny check` PASS
- [ ] `cargo audit` within warning thresholds
- [ ] `gitleaks detect` 0 finding
- [ ] 2 OS x 2 toolchain CI matrix green (P5)
- [ ] 3-site live E2E run (manual dispatch; CF / SPA / SSR)
- [ ] 7-day soak crash-0 (operator action — see `docs/soak-protocol.md`)
- [ ] soak smoke pre-run PASS (see `.agent/active/v1_1_p19_soak_smoke.md`)
- [ ] README sections 1-20 complete
- [ ] CHANGELOG v1.1.0 entry complete
- [ ] SECURITY.md / CONTRIBUTING.md / CODE_OF_CONDUCT.md present
- [ ] Cargo.lock committed
- [ ] `cargo package --workspace` PASS (skippable: all crates set `publish = false` — binary distribution model)
- [x] `cargo publish --dry-run` N/A — all 11 crates declare `publish = false`; rev_scraping is distributed as GitHub Release binaries (see `.github/workflows/release.yml`), not via crates.io
- [ ] 3 binary build PASS (rev-stealth, rev-auth, stealth-mcp)
- [ ] macOS + Linux release binaries produced
- [ ] compat snapshots (insta) all PASS
- [ ] json-schema validation PASS
- [ ] DECISION NEEDED 18 items all decided
- [ ] v1.0.0-dev profile decrypt compatibility verified
- [ ] AuthStore key source documented
- [ ] GA gate failure procedure (revert to v1.0.0 or v1.1.1 patch) documented

## Pre-Release Workflow

1. Declare feature freeze and allow only release-blocking fixes.
2. Confirm protected directories, generated artifacts, and vendored references are unchanged unless explicitly approved.
3. Run formatting, source/SPDX, dependency, secret, audit, test, clippy, schema, snapshot, package, publish dry-run, and binary build gates.
4. Review README sections 1-20, CHANGELOG v1.1.0, SECURITY.md, CONTRIBUTING.md, and CODE_OF_CONDUCT.md.
5. Verify v1.0.0-dev profile decrypt compatibility and AuthStore key source documentation.
6. Run the 3-site live E2E manual dispatch for CF, SPA, and SSR targets.
7. Start and complete the 7-day soak with crash-0 criteria.
8. Produce macOS and Linux release binaries.
9. Collect release manager, security lead, and QA lead sign-off.
10. Create the v1.1.0 GA tag only after all GA Gate items pass.
11. Push the GA tag and monitor package, binary, and deployment health.

## Rollback Plan

If any GA gate fails before tag push, stop the release, keep v1.1.0 unpublished,
open a release-blocking issue with the failing command and log path, and rerun
the full GA Gate after the fix lands.

If any GA gate fails after publish or tag push, freeze further publication,
announce the release hold, and choose one documented recovery path:

1. Revert consumers and release notes to v1.0.0 when the failure affects package
   integrity, security, compatibility, or binary correctness.
2. Publish a v1.1.1 patch when the failure is isolated, fixed, and verified by
   the full GA Gate.
3. Keep the failed artifact listed in the incident note with mitigation,
   affected versions, owner, and verification evidence.

## Package Dry-Run Results

Date: 2026-05-19

`cargo package --workspace --no-verify`: FAIL

Last 5 lines of `/tmp/p18_package_dry.log`:

```text
Caused by:
  failed to download from `https://index.crates.io/config.json`

Caused by:
  [6] Couldn't resolve host name (Could not resolve host: index.crates.io)
```

Per-crate publish dry-run:

| crate | result | note |
| --- | --- | --- |
| stealth-core | FAIL | `package.publish` is set to `false`; crate cannot be published. |
| mobile-fp | FAIL | `package.publish` is set to `false`; crate cannot be published. |
| captcha-bypass | FAIL | `package.publish` is set to `false`; crate cannot be published. |
| vpn-rotate | FAIL | `package.publish` is set to `false`; crate cannot be published. |
| stealth-sites | FAIL | `package.publish` is set to `false`; crate cannot be published. |
| stealth-parse | FAIL | `package.publish` is set to `false`; crate cannot be published. |
| stealth-cf | FAIL | `package.publish` is set to `false`; crate cannot be published. |
| obscura-bridge | FAIL | `package.publish` is set to `false`; crate cannot be published. |
| stealth-auth | FAIL | `package.publish` is set to `false`; crate cannot be published. |
| stealth-mcp | FAIL | `package.publish` is set to `false`; crate cannot be published. |
| stealth-cli | FAIL | `package.publish` is set to `false`; crate cannot be published. |

Binary build:

| binary | result | note |
| --- | --- | --- |
| rev-stealth | PASS | Built by `cargo build --release --bin rev-stealth --bin rev-auth --bin stealth-mcp`. |
| rev-auth | PASS | Built by `cargo build --release --bin rev-stealth --bin rev-auth --bin stealth-mcp`. |
| stealth-mcp | PASS | Built by `cargo build --release --bin rev-stealth --bin rev-auth --bin stealth-mcp`. |

Crate publish dry-run summary: 0 PASS / 0 WARN / 11 FAIL / 0 N/A out of 11 crates.

## Sign-Off

- [ ] Release manager sign-off
- [ ] Security lead sign-off
- [ ] QA lead sign-off
