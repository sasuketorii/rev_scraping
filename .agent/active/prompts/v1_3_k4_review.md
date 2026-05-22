# Lane K.4 reviewer prompt (Codex)

You are the v1.3 Lane K.4 reviewer. Verify acceptance from
.agent/active/v1_3_uplift_execplan_rev1.md (Lane K.4):

> proptest expansion: stealth-auth (envelope roundtrip + AAD mismatch)
> + stealth-agent-contracts (UUID v4 + IdempotencyKey + RateLimiter)
> + vpn-rotate (rotation invariants). Acceptance: each crate has ≥1
> prop test; 256 iter standard / 1024 iter nightly.

Artifacts (this fix-up driver delivered):
- crates/stealth-sanitize/tests/proptest_invariants.rs   (3 props, was already in)
- crates/stealth-agent-contracts/tests/proptest_invariants.rs   (3 props NEW)
- crates/stealth-auth/tests/proptest_envelope.rs   (3 props NEW)
- crates/vpn-rotate/tests/proptest_rotation_policy.rs   (2 props NEW)

Local verification:
- cargo test -p stealth-agent-contracts --test proptest_invariants  → 3/3 PASS
- cargo test -p stealth-auth --test proptest_envelope               → 3/3 PASS
- cargo test -p vpn-rotate --test proptest_rotation_policy          → 2/2 PASS

Constraints:
- prompt ≤ 2 KB / max 3 round / no Write/Edit
- baseline: commit 7c700a0b on main

Verify:
1. Each of the 4 crates has ≥1 proptest file.
2. cases: 256 on PR (PROPTEST_CASES env can override to 1024 nightly).
3. stealth-auth covers envelope roundtrip + AAD mismatch + profile_hash mismatch.
4. stealth-agent-contracts covers UUID v4 strict + IdempotencyKey + RateLimiter.
5. vpn-rotate covers rotation policy invariants (from_slug totality + serde roundtrip).

Return:
verdict: LGTM | CHANGES
deltas: <none | bullet list, ≤ 5 items>
