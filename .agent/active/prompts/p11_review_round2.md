# Review P11 — round 2

## Fix from round 1 BLOCK
Round 1 verdict: BLOCK — `systemd-analyze` job ran on `ubuntu-22.04` (systemd 249), but `dist/systemd/system/rev-stealth-vpn@.service` uses `LoadCredentialEncrypted=` + `%d` which need systemd >=252. Also: original command only matched `*.service`, missing the timer.

Fix in `.github/workflows/ci.yml` (`systemd-analyze` job only):
- `runs-on:` → `ubuntu-24.04` (systemd 255 per Ubuntu 24.04 LTS).
- Added a preflight step that reads `systemctl --version` and fails the job if `< 252`, so a future runner image downgrade fails fast and visibly instead of silently masking the directive.
- Glob now collects both `*.service` and `*.timer` (nullglob), and the script aborts if the array is empty.

No other CI job touched.

## Files touched this round
- .github/workflows/ci.yml (systemd-analyze job only)

## Gates PASS
- `python3 -c "yaml.safe_load(...)"` parses OK; 15 jobs registered (same set as round 1).
- `yamllint .github/workflows/ci.yml`: my new sections (275-413) contribute zero findings. Remaining `line-too-long` errors are at lines 161 / 204-205 / 248-249 / 425-426 — all pre-existing in the obscura / cdp / spider Chrome apt-install blocks, untouched in this slice.
- `cargo test --workspace`: 680 PASS / 0 fail / 38 ign (unchanged; CI file only).
- `cargo clippy --workspace --all-targets -- -D warnings`: clean (unchanged; CI file only).

## Verify (3)
1. `ubuntu-24.04` ships systemd 255 (>= the 252 cutoff documented in `docs/deploy/vps.md`), so `LoadCredentialEncrypted=` + `%d` in `rev-stealth-vpn@.service` are now actually validated. The version preflight protects against runner image downgrade by failing the job before `verify` runs.
2. The glob `dist/systemd/system/*.service dist/systemd/system/*.timer` now covers `rev-stealth-doctor.timer` alongside the four services, addressing the second part of round 1's finding.
3. No other job's `runs-on:` was changed; the rest of the CI surface (rust-fmt/clippy/test/docs/spdx/mcp-schema-lint/config-cli-smoke/hermes-contract/headless-auth/obscura e2e) is byte-identical to round 1.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`
