# Review P6.2 round 3 (round-2 narrow finding fix)

## Round 2 BLOCK
Same false-success class as round-1 (sites/) extended to policy.toml / authorized.toml when target path is a directory.

## Fix applied
File: `crates/stealth-cli/src/commands/config_cli.rs`
- New regression tests:
  - `config_init_sites_target_with_file_at_path_returns_error` (exit 3 when sites/ exists as regular file)
  - `config_init_policy_target_with_directory_at_path_returns_error` (exit 3 when policy.toml is directory, even with --force)
  - `config_init_authorized_target_with_directory_at_path_returns_error` (same for authorized.toml)

## Gates PASS
- `cargo test -p stealth-cli config_cli`: **14/14 PASS** (6 P6.1 + 8 P6.2)
- `cargo test --workspace`: **613 PASS / 0 fail** (baseline 603 → +10)
- clippy `-D warnings`: clean
- CLI smoke: `rev-stealth config init --help` exposes `--target {all|policy|authorized|sites}`, `--force`, `--non-interactive`

## Verify (3)
1. All 3 new regression tests reject directory-at-file-path with exit 3
2. ConfigWriter (P5.2) used for atomic 0600 write (no race)
3. `.bak.<epoch>` produced on --force overwrite

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`
