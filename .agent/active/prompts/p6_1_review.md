# Review P6.1 round 3 — Clap arg-id collision fixed

## Round 2 finding (now fixed)
`rev-stealth config` panicked because its local `--format` reused the Clap
arg id `format`, colliding with the global `Cli.format` (same pattern that
broke `doctor` in v0.0.4 → v1.0.0 §2.1).

Fix in `config_cli.rs::ConfigArgs`:
```
#[arg(long = "output-format", id = "config_output_format",
      value_enum, default_value_t = ConfigFormat::Text)]
pub format: ConfigFormat,
```

Runtime parse-smoke locked in `main.rs::cli_tests::config_subcommand_parses_with_global_format`:
- `rev-stealth config validate` parses
- `rev-stealth --format json config validate` parses (no panic)
- `rev-stealth config --output-format json validate` parses, format=json
- `Cli::command().debug_assert()` (clap_command_passes_debug_assert) still PASS

## Runtime evidence
`./target/release/rev-stealth config validate` actually dispatches and prints:
```
OK   /Users/sasuketorii/.rev_scraping/policy.toml
FAIL /Users/sasuketorii/.rev_scraping/authorized.toml: [UnknownField] ...
```
(no panic; real validation paths exercised end to end.)

## Files
- `crates/stealth-cli/src/commands/config_cli.rs` (~600 LoC, 6 tests)
- `crates/stealth-cli/src/commands/mod.rs` (`pub mod config_cli;`)
- `crates/stealth-cli/src/main.rs` (`Config(ConfigArgs)` variant + dispatch
  + `config_subcommand_parses_with_global_format` parse smoke)
- `crates/stealth-cli/Cargo.toml` (+`serde_yaml = "0.9"`)

## Gates PASS
- `cargo check -p stealth-cli`: clean
- `cargo test -p stealth-cli config_cli`: 6/6 PASS
- `cargo test --workspace --no-fail-fast`: 595 PASS / 0 FAIL
- `cargo clippy -p stealth-cli --tests --no-deps -- -D warnings`: clean
- CLI smoke: `config validate` runs end to end; help lists all 5 subcommands

## Carried-forward fixes
- Recursive `redact_json_tree` over policy/authorized/sites layers
- `run_validate` promotes read errors to exit 1 (text + JSON surface)

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`.
