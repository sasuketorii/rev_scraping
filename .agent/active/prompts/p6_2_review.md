# Review P6.2 config init — Round 2 (fixes for round-1 BLOCK)

file: crates/stealth-cli/src/commands/config_cli.rs

Round-1 BLOCK findings (both addressed):

1. **sites/ false-success when path exists as a non-directory**
   - Fix: `ensure_dir_0700` now returns `io::Error(NotADirectory)` when `dir.exists() && !dir.is_dir()`. `init_sites_dir` propagates that to `InitStatus::Error`, which drives `run_init` exit code 3.
   - New test: `config_init_sites_target_with_file_at_path_returns_error` plants a regular file at `sites/`, asserts exit 3, asserts the operator file is preserved byte-for-byte (no clobber).

2. **placeholder write failure downgraded to Skipped/Created**
   - Fix: `init_sites_dir` now tracks `seed_failed: bool`. When the placeholder ConfigWriter call returns Err, the outcome status is set to `InitStatus::Error` (with the underlying error in `note`). Exit code becomes 3.

gates PASS (round 2):
- cargo check -p stealth-cli: clean
- cargo test -p stealth-cli config_cli: 12/12 PASS (6 P6.1 + 6 P6.2 incl. new sites-file-collision test)
- cargo test --workspace --no-fail-fast: 611 passed / 0 failed
- cargo clippy -p stealth-cli --lib --bins --tests -- -D warnings: clean
- ./target/release/rev-stealth config init --help: flags unchanged

unchanged invariants (re-verify):
- policy.toml 0600 AT CREATION via FsConfigWriter::write_with_backup (no post-chmod).
- sites/ 0700 via DirBuilderExt::mode(0o700) atomically; placeholder 0600.
- --force routes overwrite through .bak.<epoch>; pre-overwrite bytes preserved.
- --non-interactive: no stdin reads on any code path.
- P6.1 5 subcommand tests preserved.
- no secrets introduced; SPDX preserved; vendor/_refs/baseline untouched.

return: verdict: LGTM or BLOCK: <reason>
