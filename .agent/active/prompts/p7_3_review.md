# Review P7.3 — `rev-stealth hermes` subcommand

## Scope
Lane D / P7.3. Wire a `rev-stealth hermes {install, uninstall, verify}`
subcommand that manages the Hermes plugin scaffold on disk.

## Files touched
- `crates/stealth-cli/src/commands/hermes.rs` (new — clap `HermesArgs` /
  `HermesAction`; recursive install copy; uninstall with `plugin.yaml`
  sentinel; verify with required-files + optional `python3 -c ast.parse`
  syntax probe; 10 unit tests)
- `crates/stealth-cli/src/commands/mod.rs` (declare `pub mod hermes;`)
- `crates/stealth-cli/src/main.rs` (`Command::Hermes(...)` enum variant
  + dispatch)
- `crates/stealth-cli/Cargo.toml` (add `thiserror = { workspace = true }`
  to `[dependencies]`; `tempfile` already in dev-deps)

## Gates PASS
- `cargo build -p stealth-cli`: clean
- `cargo clippy --workspace --all-targets -- -D warnings`: clean
- `cargo test --workspace`: 673 PASS / 0 fail / 38 ignored
  (baseline 663 + 10 new tests under `commands::hermes::tests::*`)
- `python3 -m unittest discover dist/hermes/rev-scraping-mcp/tests`:
  15 PASS / 0 fail (unchanged)

## Verify (3 claims)
1. `install` defaults to `$HOME/.hermes/plugins/rev-scraping-mcp`,
   refuses a non-empty destination unless `--force` is passed
   (`install_refuses_non_empty_dest_without_force`), supports
   `--source <dir>` override for the scaffold (default resolves to
   `<workspace>/dist/hermes/rev-scraping-mcp` via `CARGO_MANIFEST_DIR`),
   and recursively copies all required files while skipping
   `__pycache__` / symlink entries.
2. `uninstall` is conservative: it only removes the target dir if a
   `plugin.yaml` sentinel exists at the top level. An unrelated
   directory (or a missing path) yields `HermesError::NotAnInstall`
   rather than a destructive `remove_dir_all`. Tests:
   `uninstall_rejects_non_install_dir`, `uninstall_rejects_missing_dir`,
   `uninstall_happy_path_removes_install`.
3. `verify` enforces the `REQUIRED_FILES` set (`plugin.yaml`,
   `__init__.py`, `mcp_client.py`, `lifecycle.py`, `tool_proxy.py`,
   `schema_bridge.py`) and, when `--python-check` is on (default), runs
   `python3 -c "import ast; ast.parse(open(__init__.py).read())"` to
   confirm the entrypoint is syntactically valid. Operators in
   minimal-image environments can pass `--python-check=false`. Tests:
   `verify_happy_path_no_python_check`, `verify_detects_missing_required_file`,
   `verify_rejects_non_directory`.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`.
