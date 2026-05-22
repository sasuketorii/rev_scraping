# Review P6.3 final ping — round-3 fix applied

file: crates/stealth-cli/src/commands/config_cli.rs

Round-3 fix:
- validate-fail branch: persist_aborted_temp failure no longer triggers tmpdir cleanup. Match returns (kept_display, cleanup_tmpdir: bool); only sweep tmpdir when sibling actually landed. Otherwise report tmp_path + the persist error in kept_display.
- editor non-zero exit branch: same fix; if persist fails we report tmp_path and return WITHOUT calling cleanup(&tmpdir).

New test:
- edit_preserves_tempdir_when_recovery_sibling_write_fails (under EDIT_TMP_LOCK): chmod 0o555 on the original's parent so persist_aborted_temp fails, then verifies a `rev-stealth-edit-<pid>-*` dir survives under TMPDIR.

Gates PASS:
- config_cli: 24 PASS (14 baseline + 10 new)
- workspace (-j 2): 641 PASS / 0 FAIL
- cargo clippy -p stealth-cli --all-targets -- -D warnings clean
- SPDX preserved L1; CLI smoke 3 subcommands surface
- ConfigWriter used; secret redaction preserved; SchemaVersionRead error map preserved; render_redacted_report preserved.

return: verdict: LGTM or BLOCK: <reason>
