# Review P4.3 — round 2 (BLOCK-fix)

Round-1 block: arity guard `error_kind_has_exactly_26_variants` was not coupled to the enum definition (a 27th variant could be added without breaking the test).

Fix: added `variant_index(&ErrorKind) -> usize` in tests, attributed `#[forbid(unreachable_patterns)]`, with an exhaustive no-wildcard match arm per variant returning a unique 0..25 index. The test now asserts indices.sort().dedup() == 0..26. Adding a 27th variant now fails at compile time (no wildcard, no default) — and removing one collapses the index range.

File: crates/stealth-agent-contracts/src/error.rs (lines ~136–204).

Other files unchanged from round 1.

re-run gates:
- cargo test -p stealth-agent-contracts: 27 PASS
- cargo clippy -p stealth-agent-contracts --all-targets -- -D warnings: clean
- workspace test counts unchanged (640 PASS).

Please re-verify item 1 of round-1 verify list.

return: verdict: LGTM or BLOCK: <reason>
