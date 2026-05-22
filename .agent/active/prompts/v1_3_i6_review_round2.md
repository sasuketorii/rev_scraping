# Review v1.3 I.6 (Round 2)

R1 BLOCK addressed:

1. **Substring presence replaced with proper attribute parsing.** Added `parse_deprecated_attrs(block) -> (Option<String>, Option<String>)` that:
   - Strips outer `#[deprecated(` / `)]`.
   - Tracks string-literal boundaries with `\\` escapes so `since`/`note` inside another value's string content do NOT count.
   - Walks top-level `key = "value"` pairs at depth-0 with an explicit byte-level state machine.
   - Returns `Some(value)` only when the key is an actual attribute argument with a non-empty literal.

   Substring bug now regression-tested: `note = "deprecated since v1.0; …"` must NOT satisfy the `since` requirement.

2. **Smoke test expanded** 1 case → 5 cases (bare / missing hint / missing since / well-formed accepted / substring-bug regression).

## Files touched (delta)
- `crates/stealth-cli/tests/deprecated_completeness.rs` — `parse_deprecated_attrs()` parser (~80 LOC), `audit_file()` rewritten, 5-case smoke test.

## Gates PASS
- `cargo test -p stealth-cli --test deprecated_completeness` → 2 passed / 0 failed.
- `cargo test -p stealth-cli` → 258 passed.

## Verify (3)
1. Parser is string-literal aware. `#[deprecated(note = "deprecated since v1.0")]` → `(None, Some(...))` ⇒ `since` finding fires.
2. Multi-line attribute (`since`/`note` on separate lines) is correctly coalesced.
3. Bare `#[deprecated]` still flagged. Escape hatch `// I6-LINT: skip` functional. Tests dirs skipped.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`.
