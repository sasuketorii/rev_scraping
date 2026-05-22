# Review v1.3 I.6 — #[deprecated(...)] completeness lint

## Files touched
- `crates/stealth-cli/tests/deprecated_completeness.rs` (new, +180 LOC, 2 tests)

## Gates PASS
- `cargo test -p stealth-cli --test deprecated_completeness` → 2 passed / 0 failed
  - `every_deprecated_attribute_is_actionable` — workspace-wide scan (0 violations today)
  - `lint_smoke_detects_missing_metadata` — self-test on a synthetic bad sample (2 findings)
- No new dependencies (tempfile already in dev-deps).
- Full `cargo test -p stealth-cli` → 258 passed.

## Verify (3)
1. Every `#[deprecated(...)]` attribute on any `pub` item under `crates/*/src/`
   must declare:
   - `since = "<version>"`
   - `note = "..."` (non-empty)
   - inside `note`, one of: `replace_with`, `Use `, `use `, `replaced by`, `Prefer `, `prefer ` (replacement hint)
2. Bare `#[deprecated]` (no args) is rejected.
3. Escape hatch documented (`// I6-LINT: skip` on the preceding line) for
   vendored or generated code; not used today. Test/tests dirs skipped to allow
   intentional bare-attribute usage in assertions.

Implementation choice: textual scan (not custom clippy lint) so the rule runs
on stable Rust every contributor has, with no nightly toolchain dependency.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`.
