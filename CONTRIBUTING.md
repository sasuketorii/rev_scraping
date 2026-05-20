<!-- SPDX-License-Identifier: MIT -->

# Contributing to rev_scraping

Thank you for considering a contribution. `rev_scraping` is a
**defender-facing evaluation toolkit**; please read the
[Authorized Targets Only](./README.md#-authorized-targets-only--read-this-before-running-anything)
section and [`SECURITY.md`](./SECURITY.md) before you start.

This project adopts the [Contributor Covenant 2.1](./docs/CODE_OF_CONDUCT.md).

## 1. Development setup

```bash
# Toolchain (pinned via workspace.rust-version = 1.83)
rustup toolchain install 1.83
rustup default 1.83
rustup component add rustfmt clippy

# Build obscura out of tree (Apache-2.0 — see NOTICE)
( cd vendor/obscura && cargo build --release )

# Build + check the workspace
cargo check --workspace
cargo build --release --workspace
cargo test --workspace --no-fail-fast
```

For the supply-chain gates that CI runs:

```bash
cargo install cargo-deny cargo-audit
cargo deny check
cargo audit
./scripts/check_source_and_spdx.sh
./scripts/check_bsl_contamination.sh
```

## 2. Code rules

- **Edition / MSRV**: 2021 / 1.83 (see `[workspace.package]`).
- **`unsafe`**: forbidden workspace-wide. Do not add it.
- **SPDX header**: every `.rs`, `.md`, `.toml` (non-`Cargo.toml`), and
  shell file must begin with `// SPDX-License-Identifier: MIT` (or
  the comment variant appropriate for the file type). The check is
  enforced by `scripts/check_source_and_spdx.sh`.
- **Licenses**: contributions are MIT. Vendored Apache-2.0 lives only
  under `vendor/obscura/`. BSL is **forbidden** anywhere in the tree
  (`scripts/check_bsl_contamination.sh`).
- **`clippy`**: `cargo clippy --workspace --all-targets -- -D warnings`
  must pass.
- **`rustfmt`**: `cargo fmt --all` before committing.

## 3. Test naming

- Unit tests live next to the code in `mod tests`. Name them
  `<unit>_<behaviour>_<expectation>`, e.g. `relocate_strsim_below_threshold_returns_exit10`.
- Integration tests under `crates/<crate>/tests/` use `it_<topic>`
  prefix (e.g. `it_spider_aup_rejected.rs`).
- E2E tests under top-level `tests/` use `e2e_<topic>` prefix.
- A new test must be deterministic (no live network unless gated
  behind `#[ignore]` + a `REV_SCRAPING_E2E=1` env opt-in).

## 4. Pull request format

Title: `<area>: <imperative summary>` (e.g. `stealth-auth: redact cookie value in trace`).

Body template:

```
## What
<one paragraph>

## Why
<link to ExecPlan section, issue, or audit finding>

## How
- <bullet>
- <bullet>

## Test plan
- [ ] cargo check --workspace
- [ ] cargo test --workspace --no-fail-fast (existing PASS count maintained)
- [ ] cargo clippy --workspace --all-targets -- -D warnings
- [ ] SPDX + BSL scripts pass

## Risk
<rollback notes / blast radius>
```

A reviewer will check: scope creep, secret leakage, AUP bypass
potential, supply-chain delta (new transitive deps), and whether the
change needs a `CHANGELOG.md` entry under `[Unreleased]`.

## 5. What we will not merge

- Code that bypasses the AUP allowlist or the VPN-required guard
  silently.
- Automated credential entry, 2FA solving, CAPTCHA solving, or
  passkey replay (explicitly out of scope — see README §14).
- Vendoring BSL-licensed code in any form.
- New dependencies on RC / pre-1.0 crates without a feature gate.

If in doubt, open a draft PR and ask.
