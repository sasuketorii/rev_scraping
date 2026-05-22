# Phase 10 Lane A P2 + Lane B P5.1 — Combined Review

## Slice scope
Two sub-phases bundled in Lane A coder round 1:
1. **P2**: `rev-auth --headless` / `--xvfb` flag (DisplayMode enum + resolver)
2. **P5.1**: `config_io` schema + validate engine (deny_unknown_fields + levenshtein + schema_version=1)

## Spec sources
- `$REPO_ROOT/.agent/active/v1.2.0_execplan_rev1.md` §L (P2 + P5.1 rows)
- `$REPO_ROOT/.agent/active/v1_1_followup_vps_audit.md` (B5 rev-auth --headless)
- `$REPO_ROOT/.agent/active/v1_1_followup_config_ux.md` (config_io schema)

## Files to review

### P2
- `crates/stealth-auth/src/bin/rev_auth.rs` (+~450 lines: DisplayMode enum, resolve_login_display_mode, EnvLookup, TargetOs, mutual-exclusion validation, xvfb-run probe)
- `crates/stealth-auth/src/audit.rs` (+21 lines: display_mode field)

### P5.1
- `crates/stealth-cli/src/config_io/{mod,schema,validate,lev}.rs` (new module)
- `crates/stealth-cli/src/lib.rs` (new re-export)
- `crates/stealth-cli/src/policy.rs` (deny_unknown_fields + schema_version)
- `crates/stealth-cli/src/{main.rs,vpn_guard.rs,vpn_selector.rs,commands/vpn_envelope.rs}` (config_io re-export wiring)
- `crates/stealth-cli/tests/config_io_v1_1_0_compat.rs` (compat test)

## Gates already verified by coder
- `cargo check --workspace --all-targets`: PASS
- `cargo test --workspace --no-fail-fast`: 536 PASS / 0 FAIL / 38 IGNORED (baseline 519 + 17)
- `cargo clippy --workspace --all-targets -- -D warnings`: PASS
- `scripts/check_source_and_spdx.sh`: PASS
- `scripts/check_baseline_diff.sh`: 15 tools / 11 packages OK
- secret-leak grep: clean

## Review focus
1. **P2 DisplayMode**:
   - 8 mandated tests present (display_mode_auto_macos_resolves_headed, etc.)
   - mutual exclusion `--headless` vs `--xvfb` enforced
   - env var `REV_AUTH_DISPLAY` precedence correct
   - xvfb-run probe is best-effort (no PATH coupling failures)
   - `audit.rs` display_mode field added without breaking existing JSONL consumers

2. **P5.1 config_io**:
   - `#[serde(deny_unknown_fields)]` on Policy + AuthorizedTarget
   - `schema_version: u32 = 1` default via `#[serde(default = "default_schema_version")]`
   - Levenshtein suggestion accurate ("requite_vpn" → "require_vpn")
   - `templates/policy.toml` still validates (compat test)
   - Existing `policy.rs::Policy` public API NOT broken
   - 6 unit tests cover boundary cases

3. **Cross-slice safety**:
   - No source-tree changes outside the listed files
   - v1.1.0 existing 519 tests preserved
   - No new `crates/*/Cargo.toml` workspace member additions outside spec (only new tests + new module file)

## Verdict required
- `verdict: LGTM` — both P2 and P5.1 accepted
- `verdict: BLOCK` — list specific findings with file:line + suggested fix

Return verdict in last line.
