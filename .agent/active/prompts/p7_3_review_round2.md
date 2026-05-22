# Review P7.3 — `rev-stealth hermes` subcommand (round 2)

## Round 1 verdict
BLOCK on a single finding:
- `rev-stealth hermes verify --python-check=false` was advertised in
  the docstring and reviewer-claim 3 as the no-Python escape hatch,
  but clap parsed `python_check: bool` as a flag (no value form) and
  rejected `--python-check=false`. The internal unit test constructed
  `VerifyArgs { python_check: false }` directly, so it missed the CLI
  parsing regression.

## Round 2 fix
- `crates/stealth-cli/src/commands/hermes.rs`:
  * Renamed the CLI knob to `--skip-python-check` (a true clap flag,
    default off), with `--no-python-check` as a clap `alias`. Operators
    in minimal-image environments without `python3` use either form.
    The default behavior (probe enabled) is unchanged.
  * Added `VerifyArgs::python_check_enabled() -> bool` so the rest of
    the module reads the intent rather than the negated field.
  * Updated `verify()` to call `args.python_check_enabled()` and
    updated the two unit tests that constructed `VerifyArgs` to use
    `skip_python_check: true` for the "skip" case.
  * New `cli_parses_skip_python_check_and_alias` test parses three
    invocations through a clap `Probe::try_parse_from(...)`:
    `--skip-python-check`, the `--no-python-check` alias, and the
    default (no flag). All three resolve to the expected
    `python_check_enabled()` boolean.

## Files touched in this round
- `crates/stealth-cli/src/commands/hermes.rs`

## CLI smoke (manual probe, mirrors reviewer's repro)
```
$ cargo run -q -p stealth-cli -- hermes verify --no-python-check --prefix /tmp/nonexistent
hermes verify failed: install dir /tmp/nonexistent does not look like a rev-scraping-mcp install (no plugin.yaml)

$ cargo run -q -p stealth-cli -- hermes verify --skip-python-check --prefix /tmp/nonexistent
hermes verify failed: install dir /tmp/nonexistent does not look like a rev-scraping-mcp install (no plugin.yaml)

$ cargo run -q -p stealth-cli -- hermes verify --help
...
      --skip-python-check  Skip the `python3 -c ...` syntax probe of `__init__.py`. ...
```
Both forms parse and reach the verify path; `--help` advertises only
`--skip-python-check` while still accepting the `--no-python-check`
alias (clap behaviour).

## Gates PASS
- `cargo test -p stealth-cli commands::hermes`: 11 PASS / 0 fail
  (was 10 + 1 new CLI parse regression test).
- `cargo test --workspace`: **674 PASS** / 0 fail / 38 ignored
  (was 673; +1 CLI parse regression). Three consecutive default-thread
  runs all clean.
- `cargo clippy --workspace --all-targets -- -D warnings`: clean.
- `python3 -m unittest discover dist/hermes/rev-scraping-mcp/tests`:
  20 PASS / 0 fail (unchanged).

## Verify (3 claims)
1. `--skip-python-check` and the `--no-python-check` alias both parse
   through clap and disable the `python3` syntax probe in the verify
   path. Default (neither flag) keeps the probe on. Regression test:
   `cli_parses_skip_python_check_and_alias`.
2. `verify()` still enforces the `REQUIRED_FILES` set independently of
   the python-check flag, and `python_check_enabled()` is the single
   boolean read by the probe gate (no other call sites use the field).
3. The other two subcommands (`install`, `uninstall`) and their
   safety rails (empty-dest gate, force overwrite, `plugin.yaml`
   sentinel guard) are unchanged; their 8 tests still pass.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`.
