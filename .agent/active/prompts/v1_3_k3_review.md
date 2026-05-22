# Lane K.3 reviewer prompt (Codex)

You are the v1.3 Lane K.3 reviewer. Verify acceptance from
.agent/active/v1_3_uplift_execplan_rev1.md (Lane K.3):

> #![forbid(unsafe_code)] on every crate root; obscura-bridge exempted
> with #![deny(unsafe_op_in_unsafe_fn)] + SAFETY doc lint. Acceptance:
> grep verification CI step; SAFETY doc check on every unsafe block.

Artifacts:
- crates/*/src/lib.rs (and bin entry points)
- .github/workflows/security.yml (forbid-unsafe-lint job)

Constraints:
- prompt ≤ 2 KB / max 3 round / no Write/Edit
- baseline: commit 7c700a0b on main
- 13 crates exist in crates/

Verify:
1. Run `grep -rE "forbid\\(unsafe_code\\)" crates/*/src/lib.rs` —
   expect 13/13 matches (or 12 + obscura-bridge using deny variant).
2. obscura-bridge has `#![deny(unsafe_op_in_unsafe_fn)]` (allowed
   exemption).
3. CI step enforces this (grep verification in security.yml).

Return:
verdict: LGTM | CHANGES
deltas: <none | bullet list, ≤ 5 items>
