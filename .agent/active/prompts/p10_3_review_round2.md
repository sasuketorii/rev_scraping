# Review P10.3 round 2 (JSON contract fix)

## Round 1 BLOCK
`--vps --output-format json` emitted `{doctor, deep?, vps}` object instead of `[DeepCheck, ...]` array.

## Fix applied (single file: crates/stealth-cli/src/doctor.rs)
- L259-277: --vps && JSON now emits top-level `Vec<DeepCheck>` (deep rows ++ vps rows concat)
- L303-313: removed CombinedJson envelope, added `deep_report_rows()` helper
- L1338+: test rewritten to `vps_json_output_is_single_top_level_array` asserts `starts_with('[')` + `is_array`
- new test `deep_plus_vps_json_concatenates_rows_in_order`

## Gates PASS
- workspace **610 PASS / 0 fail** (baseline 603 → +7)
- clippy clean
- 実機 stdout first byte = `[` confirmed

## Verify (3)
1. `--vps` JSON output = top-level array `[DeepCheck, ...]`
2. `--deep --vps` JSON = flat concat (deep first, then vps)
3. Leak exit 7 contract untouched

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`
