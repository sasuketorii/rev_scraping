# Review P5.2 round 2 (security fix)

## Round 1 BLOCK
"temp/backup files must be created with 0600 before any exposure window"

## Fix applied
File: `crates/stealth-cli/src/config_io/writer.rs`
- L106-129: backup file → `OpenOptions::new().write(true).create_new(true).mode(0o600).open()`, post-creation chmod removed
- L144-159: tmp file → `OpenOptions + mode(0o600) + write_all + sync_all`, post-creation chmod removed
- `#[cfg(unix)]` gates Windows path (ACL TODO)
- L289-336: 2 new tests `tmp_file_created_with_0600_mode_directly`, `backup_file_created_with_0600_mode_directly`

## Gates PASS
- cargo test workspace: **559 PASS / 0 fail** (557 → +2)
- cargo test -p stealth-cli writer: 8/8 (6 existing + 2 new)
- clippy clean
- baseline diff: in-scope

## Verify (3 checks)
1. No `set_permissions` call after open in tmp/backup paths
2. `mode(0o600)` set inside `OpenOptions` builder chain
3. Tests assert mode AT creation, not post-chmod

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`
