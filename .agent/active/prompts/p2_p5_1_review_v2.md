# Review: P2 + P5.1 (Phase 10 Lane A bundle)

## Files touched
- `crates/stealth-auth/src/bin/rev_auth.rs` (P2: DisplayMode + headless/xvfb flags + resolver)
- `crates/stealth-auth/src/audit.rs` (P2: display_mode field)
- `crates/stealth-cli/src/config_io/{mod,schema,validate,lev}.rs` (P5.1 new module)
- `crates/stealth-cli/src/policy.rs` (P5.1: deny_unknown_fields + schema_version=1)
- `crates/stealth-cli/src/lib.rs` (new re-export)
- `crates/stealth-cli/tests/config_io_v1_1_0_compat.rs`

## Gates already PASS
- cargo test --workspace: **536 PASS / 0 FAIL** (baseline 519 + 17)
- cargo clippy -D warnings: clean
- SPDX: PASS
- baseline diff: 15 tools / 11 packages OK
- secret-leak grep: clean

## Verify (5 checks)
1. `DisplayMode` mutual exclusion (--headless XOR --xvfb)
2. `REV_AUTH_DISPLAY` env var precedence honored
3. `#[serde(deny_unknown_fields)]` on Policy + AuthorizedTarget
4. `schema_version: u32 = 1` default present
5. Existing `policy.rs::Policy` public API not broken (`templates/policy.toml` still validates)

## Return
Last line: `verdict: LGTM` (accept both) or `verdict: BLOCK: <reason>`
