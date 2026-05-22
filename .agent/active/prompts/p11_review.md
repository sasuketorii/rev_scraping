# Review P11 — CI workflow extension

## Files touched
- .github/workflows/ci.yml (added 5 new jobs to the existing CI; pre-existing rust-fmt/-clippy/-test/-docs/-spdx/-obscura-e2e jobs untouched)

## New jobs (all ubuntu-22.04, timeout-minutes: 25, no matrix)
1. `mcp-schema-lint` — runs `cargo run -p stealth-mcp --bin gen_reference -- --check` (P8 freshness gate).
2. `config-cli-smoke` — builds `rev-stealth`, then runs `config init --target=policy --non-interactive --force` inside a throwaway $HOME and asserts `~/.rev_scraping/policy.toml` materializes.
3. `hermes-contract` — installs python 3.11 via actions/setup-python and runs `python3 -m unittest discover dist/hermes/rev-scraping-mcp/tests` (20-test suite).
4. `systemd-analyze` — runs `systemd-analyze verify dist/systemd/system/*.service` (ubuntu pre-installed).
5. `headless-auth` — explicit skip placeholder. Uses `if: false` on the real step so the job is visible in the run graph but does no work; included so a later lane can flip the gate without renaming a required check.

## Gates PASS
- `cargo test --workspace`: 680 PASS / 0 fail / 38 ign (P8 freshness test + 4 reference unit tests; unchanged from P8 LGTM).
- `cargo clippy --workspace --all-targets -- -D warnings`: clean.
- `python3 -c "yaml.safe_load(...)"` parses the workflow; jobs list = [fmt, check, clippy, test, docs, spdx, build-obscura, test-obscura-lifecycle, test-cdp-shim-lifecycle, mcp-schema-lint, config-cli-smoke, hermes-contract, systemd-analyze, headless-auth, test-spider-fallback].
- `yamllint .github/workflows/ci.yml` introduces no new findings in the lines I added (275-383). Remaining `line-too-long` errors are at 161 / 204-205 / 248-249 / 401-402 — all pre-existing in the obscura / cdp / spider Chrome apt-install blocks, untouched in this slice.
- Local smoke for `config-cli-smoke` job recipe: ran the same `mktemp -d` + `HOME=` + `rev-stealth config init` + `test -f` sequence on the host; policy.toml materialized as expected.
- Local smoke for `hermes-contract` recipe: `python3 -m unittest discover dist/hermes/rev-scraping-mcp/tests` → 20/20 PASS.

## Verify (3)
1. The new `mcp-schema-lint` job runs the same `--check` invocation the freshness test already locks; it is a CI-level mirror of the regression test, not a replacement, so the gate stays correct even if the regression test is moved or renamed.
2. `config-cli-smoke` operates in a hermetic `$HOME` (via `mktemp -d`) and only asserts the non-interactive contract documented in P6.2; it never edits the runner's real home directory and exits 0 on the documented happy path.
3. `headless-auth` is wired in deliberately as a skipped opt-in slot — the placeholder step has `if: false` so the job succeeds without doing any work; a follow-up lane can flip that single boolean rather than redefining a required check name.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`
