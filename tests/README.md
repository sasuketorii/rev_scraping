# rev_scraping — Test Strategy (Phase 4)

This directory is reserved for future workspace-level integration tests.
The current Phase-4 E2E tests live next to the binary that runs them, at:

- `crates/stealth-cli/tests/e2e_spider_smoke.rs`          (Phase 2 baseline)
- `crates/stealth-cli/tests/e2e_aup_enforcement.rs`       (Phase 4, S12)
- `crates/stealth-cli/tests/e2e_relocate_html_fixture.rs` (Phase 4, relocate)
- `crates/stealth-cli/tests/e2e_cf_evaluate_smoke.rs`     (Phase 4, cf-evaluate wire-up)
- `crates/stealth-mcp/tests/mcp_conformance.rs`           (Phase 3, S5)
- `crates/obscura-bridge/tests/obscura_lifecycle.rs`      (Phase 1a, S2/S11)
- `crates/stealth-parse/tests/golden_relocate.rs`         (Phase 1c, S4)

## Running

All E2E tests are marked `#[ignore]` so they don't run on plain `cargo test`.

```bash
# Default: only unit tests
cargo test --workspace

# Opt-in: include ignored E2E
cargo test --workspace -- --ignored

# Live env switch (recognised by some E2E for stricter assertions)
REV_SCRAPING_RUN_LIVE=1 cargo test --workspace -- --ignored
```

## Future work — fully-live obscura E2E

A complete `tests/e2e_spider_cf_relocate.rs` that spawns:

1. a local mock HTTP server returning a Cloudflare-challenge page
   (`<title>Just a moment...</title>` + Turnstile script tag),
2. flipping to a normal page after a delay,
3. the real `obscura` binary with `chromiumoxide` CDP,

is **out of scope for Phase 4** because it requires the `obscura` binary
to be built and discoverable on the test host. The Phase 4 deliverables
instead exercise:

- AUP enforcement (deterministic, host-independent)
- relocate via html-file fixture (no network, no browser)
- cf-evaluate subcommand wire-up (proves the CLI surface exists)

The full live E2E will be filed as a follow-up issue once an obscura
build pipeline is added to CI.
