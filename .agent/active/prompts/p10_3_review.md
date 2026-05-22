# Review P10.3 doctor --vps deep checks

files: crates/stealth-cli/src/doctor.rs (+499 lines; run_vps_checks + --vps flag + 6 unit tests in tests::vps)

gates PASS:
- cargo test -p stealth-cli --no-fail-fast: 201 passed (baseline 194; +7 incl. one reused name)
- cargo test --workspace --no-fail-fast: 596 passed (target ≥587)
- cargo clippy -p stealth-cli --all-targets -- -D warnings: clean
- SPDX header preserved (MIT)
- ./target/release/rev-stealth doctor --help exposes --vps with help text

verify:
1. 9 vps checks emitted in stable order: systemd / user_rev-stealth / dir_/var/log/rev-stealth (mode 0750) / dir_/var/lib/rev-stealth (mode 0700) / credstore (0700) / chrome_xvfb / docker (+ compose) / gluetun_image / display_env.
2. Each row returns DeepCheck { name, status, detail } reusing the --deep schema. Status enum serialises lowercase ("pass"/"warn"/"fail").
3. JSON output is an array of DeepCheck objects; text output prefixes each with [PASS]/[WARN]/[FAIL]. Smoke run confirmed both shapes.
4. Exit code aggregation:
   - leak checks PASS + vps any FAIL → std::process::exit(3) (gated by `report.all_pass()` so leak exit 7 still wins).
   - vps WARN-only → exit 0 via ExitCode::Ok mapping.
   - all-ok → exit 0.
   Pinned by test `vps_doctor_exit_code_aggregates_correctly` via `vps_has_fail`.
5. Existing tests preserved: 17 prior doctor tests (default_is_all_fail, all_pass_*, deep_*, exit_leak_detected_is_seven) all still pass; the leak-fail-closed contract (EXIT_LEAK_DETECTED=7) is unchanged.
6. No new module/file; all additions inside doctor.rs. No edits to vendor/_refs/baseline. No secrets.

new tests (in mod tests::vps):
- vps_check_systemd_present_or_warns
- vps_check_rev_stealth_user_returns_warn_when_missing
- vps_check_dir_perm_detects_wrong_mode (creates a 0o755 tempdir → asserts Fail)
- vps_doctor_exit_code_aggregates_correctly
- vps_check_set_has_at_least_nine_rows_in_stable_order
- vps_rows_serialise_to_array_of_objects

return: verdict: LGTM or BLOCK: <reason>
